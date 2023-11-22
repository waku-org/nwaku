when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
import
  ../node/peer_manager,
  ../utils/requests,
  ./protocol_metrics,
  ./common,
  ./rpc,
  ./rpc_codec

when defined(waku_exp_store_resume):
  import std/[sequtils, times]
  import ../waku_archive
  import ../waku_core/message/digest


logScope:
  topics = "waku store client"


const DefaultPageSize*: uint = 20 # A recommended default number of waku messages per page


type WakuStoreClient* = ref object
      peerManager: PeerManager
      rng: ref rand.HmacDrbgContext

      # TODO: Move outside of the client
      when defined(waku_exp_store_resume):
        store: ArchiveDriver

proc new*(T: type WakuStoreClient,
          peerManager: PeerManager,
          rng: ref rand.HmacDrbgContext): T =
  WakuStoreClient(peerManager: peerManager, rng: rng)

proc sendHistoryQueryRPC(w: WakuStoreClient, req: HistoryQuery, peer: RemotePeerInfo): Future[HistoryResult] {.async, gcsafe.} =

  let connOpt = await w.peerManager.dialPeer(peer, WakuStoreCodec)
  if connOpt.isNone():
    waku_store_errors.inc(labelValues = [dialFailure])
    return err(HistoryError(kind: HistoryErrorKind.PEER_DIAL_FAILURE, address: $peer))

  let connection = connOpt.get()


  let reqRpc = HistoryRPC(requestId: generateRequestId(w.rng), query: some(req.toRPC()))
  await connection.writeLP(reqRpc.encode().buffer)


  let buf = await connection.readLp(MaxRpcSize.int)
  let respDecodeRes = HistoryRPC.decode(buf)
  if respDecodeRes.isErr():
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return err(HistoryError(kind: HistoryErrorKind.BAD_RESPONSE, cause: decodeRpcFailure))

  let respRpc = respDecodeRes.get()


  # Disabled ,for now, since the default response is a possible case (no messages, pagesize = 0, error = NONE(0))
  # TODO: Rework the RPC protocol to differentiate the default value from an empty value (e.g., status = 200 (OK))
  #        and rework the protobuf parsing to return Option[T] when empty values are received
  if respRpc.response.isNone():
    waku_store_errors.inc(labelValues = [emptyRpcResponseFailure])
    return err(HistoryError(kind: HistoryErrorKind.BAD_RESPONSE, cause: emptyRpcResponseFailure))

  let resp = respRpc.response.get()

  return resp.toAPI()


proc query*(w: WakuStoreClient, req: HistoryQuery, peer: RemotePeerInfo): Future[HistoryResult] {.async, gcsafe.} =
  return await w.sendHistoryQueryRPC(req, peer)



# TODO: Move outside of the client
when defined(waku_exp_store_resume):
  ## Resume store

  const StoreResumeTimeWindowOffset: Timestamp = getNanosecondTime(20)  ## Adjust the time window with an offset of 20 seconds

  proc new*(T: type WakuStoreClient,
            peerManager: PeerManager,
            rng: ref rand.HmacDrbgContext,
            store: ArchiveDriver): T =
    WakuStoreClient(peerManager: peerManager, rng: rng, store: store)


  proc queryAll(w: WakuStoreClient, query: HistoryQuery, peer: RemotePeerInfo): Future[WakuStoreResult[seq[WakuMessage]]] {.async, gcsafe.} =
    ## A thin wrapper for query. Sends the query to the given peer. when the  query has a valid pagingInfo,
    ## it retrieves the historical messages in pages.
    ## Returns all the fetched messages, if error occurs, returns an error string

    # Make a copy of the query
    var req = query

    var messageList: seq[WakuMessage] = @[]

    while true:
      let queryRes = await w.query(req, peer)
      if queryRes.isErr():
        return err($queryRes.error)

      let response = queryRes.get()

      messageList.add(response.messages)

      # Check whether it is the last page
      if response.cursor.isNone():
        break

      # Update paging cursor
      req.cursor = response.cursor

    return ok(messageList)

  proc queryLoop(w: WakuStoreClient, req: HistoryQuery, peers: seq[RemotePeerInfo]): Future[WakuStoreResult[seq[WakuMessage]]]  {.async, gcsafe.} =
    ## Loops through the peers candidate list in order and sends the query to each
    ##
    ## Once all responses have been received, the retrieved messages are consolidated into one deduplicated list.
    ## if no messages have been retrieved, the returned future will resolve into a result holding an empty seq.
    let queryFuturesList = peers.mapIt(w.queryAll(req, it))

    await allFutures(queryFuturesList)

    let messagesList = queryFuturesList
      .map(proc (fut: Future[WakuStoreResult[seq[WakuMessage]]]): seq[WakuMessage] =
        try:
          # fut.read() can raise a CatchableError
          # These futures have been awaited before using allFutures(). Call completed() just as a sanity check.
          if not fut.completed() or fut.read().isErr():
            return @[]

          fut.read().value
        except CatchableError:
          return @[]
      )
      .concat()
      .deduplicate()

    return ok(messagesList)


  proc put(store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage): Result[void, string] =
    let
      digest = waku_archive.computeDigest(message)
      messageHash = computeMessageHash(pubsubTopic, message)
      receivedTime = if message.timestamp > 0: message.timestamp
                    else: getNanosecondTime(getTime().toUnixFloat())

    store.put(pubsubTopic, message, digest, messageHash, receivedTime)

  proc resume*(w: WakuStoreClient,
              peerList = none(seq[RemotePeerInfo]),
              pageSize = DefaultPageSize,
              pubsubTopic = DefaultPubsubTopic): Future[WakuStoreResult[uint64]] {.async, gcsafe.} =
    ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku store node has been online
    ## messages are stored in the store node's messages field and in the message db
    ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message
    ## an offset of 20 second is added to the time window to count for nodes asynchrony
    ## peerList indicates the list of peers to query from.
    ## The history is fetched from all available peers in this list and then consolidated into one deduplicated list.
    ## Such candidates should be found through a discovery method (to be developed).
    ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from.
    ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
    ## the resume proc returns the number of retrieved messages if no error occurs, otherwise returns the error string

    # If store has not been provided, don't even try
    if w.store.isNil():
      return err("store not provided (nil)")

    # NOTE: Original implementation is based on the message's sender timestamp. At the moment
    #       of writing, the sqlite store implementation returns the last message's receiver
    #       timestamp.
    #  lastSeenTime = lastSeenItem.get().msg.timestamp
    let
      lastSeenTime = w.store.getNewestMessageTimestamp().get(Timestamp(0))
      now = getNanosecondTime(getTime().toUnixFloat())

    debug "resuming with offline time window", lastSeenTime=lastSeenTime, currentTime=now

    let
      queryEndTime = now + StoreResumeTimeWindowOffset
      queryStartTime = max(lastSeenTime - StoreResumeTimeWindowOffset, 0)

    let req = HistoryQuery(
      pubsubTopic: some(pubsubTopic),
      startTime: some(queryStartTime),
      endTime: some(queryEndTime),
      pageSize: uint64(pageSize),
      ascending: true
    )

    var res: WakuStoreResult[seq[WakuMessage]]
    if peerList.isSome():
      debug "trying the candidate list to fetch the history"
      res = await w.queryLoop(req, peerList.get())

    else:
      debug "no candidate list is provided, selecting a random peer"
      # if no peerList is set then query from one of the peers stored in the peer manager
      let peerOpt = w.peerManager.selectPeer(WakuStoreCodec)
      if peerOpt.isNone():
        warn "no suitable remote peers"
        waku_store_errors.inc(labelValues = [peerNotFoundFailure])
        return err("no suitable remote peers")

      debug "a peer is selected from peer manager"
      res = await w.queryAll(req, peerOpt.get())

    if res.isErr():
      debug "failed to resume the history"
      return err("failed to resume the history")


    # Save the retrieved messages in the store
    var added: uint = 0
    for msg in res.get():
      let putStoreRes = w.store.put(pubsubTopic, msg)
      if putStoreRes.isErr():
        continue

      added.inc()

    return ok(added)
