## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md

{.push raises: [Defect].}

# Group by std, external then internal imports
import
  # std imports
  std/[tables, times, sequtils, algorithm, options, math],
  # external imports
  bearssl,
  chronicles,
  chronos, 
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  libp2p/varint,
  metrics,
  stew/[results, byteutils],
  # internal imports
  ../../node/storage/message/message_store,
  ../../node/peer_manager/peer_manager,
  ../../utils/requests,
  ../../utils/time,
  ../waku_swap/waku_swap,
  ./waku_store_types

# export all modules whose types are used in public functions/types
export 
  options,
  chronos,
  bearssl,
  minprotobuf,
  peer_manager,
  waku_store_types

declarePublicGauge waku_store_messages, "number of historical messages", ["type"]
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_store_errors, "number of store protocol errors", ["type"]
declarePublicGauge waku_store_queries, "number of store queries received"

logScope:
  topics = "wakustore"

const
  WakuStoreCodec* = "/vac/waku/store/2.0.0-beta4"
  DefaultStoreCapacity* = 50000 # Default maximum of 50k messages stored

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"

# TODO Move serialization function to separate file, too noisy
# TODO Move pagination to separate file, self-contained logic

proc computeIndex*(msg: WakuMessage,
                   receivedTime = getNanosecondTime(getTime().toUnixFloat()),
                   pubsubTopic = DefaultTopic): Index =
  ## Takes a WakuMessage with received timestamp and returns its Index.
  ## Received timestamp will default to system time if not provided.
  var ctx: sha256
  ctx.init()
  ctx.update(msg.contentTopic.toBytes()) # converts the contentTopic to bytes
  ctx.update(msg.payload)
  let digest = ctx.finish() # computes the hash
  ctx.clear()

  let
    receiverTime = receivedTime
    index = Index(digest:digest,
                  receiverTime: receiverTime, 
                  senderTime: msg.timestamp,
                  pubsubTopic: pubsubTopic)

  return index

proc encode*(index: Index): ProtoBuffer =
  ## encodes an Index object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  var output = initProtoBuffer()

  # encodes index
  output.write(1, index.digest.data)
  output.write(2, zint64(index.receiverTime))
  output.write(3, zint64(index.senderTime))
  output.write(4, index.pubsubTopic)

  return output

proc encode*(pinfo: PagingInfo): ProtoBuffer =
  ## encodes a PagingInfo object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  var output = initProtoBuffer()

  # encodes pinfo
  output.write(1, pinfo.pageSize)
  output.write(2, pinfo.cursor.encode())
  output.write(3, uint32(ord(pinfo.direction)))

  return output

proc init*(T: type Index, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns an Index object out of buffer
  var index = Index()
  let pb = initProtoBuffer(buffer)

  var data: seq[byte]
  discard ? pb.getField(1, data)

  # create digest from data
  index.digest = MDigest[256]()
  for count, b in data:
    index.digest.data[count] = b

  # read the timestamp
  var receiverTime: zint64
  discard ? pb.getField(2, receiverTime)
  index.receiverTime = Timestamp(receiverTime)

  # read the timestamp
  var senderTime: zint64
  discard ? pb.getField(3, senderTime)
  index.senderTime = Timestamp(senderTime)

  # read the pubsubTopic
  discard ? pb.getField(4, index.pubsubTopic)

  return ok(index) 

proc init*(T: type PagingInfo, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingInfo object out of buffer
  var pagingInfo = PagingInfo()
  let pb = initProtoBuffer(buffer)

  var pageSize: uint64
  discard ? pb.getField(1, pageSize)
  pagingInfo.pageSize = pageSize


  var cursorBuffer: seq[byte]
  discard ? pb.getField(2, cursorBuffer)
  pagingInfo.cursor = ? Index.init(cursorBuffer)

  var direction: uint32
  discard ? pb.getField(3, direction)
  pagingInfo.direction = PagingDirection(direction)

  return ok(pagingInfo) 

proc init*(T: type HistoryContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  # ContentTopic corresponds to the contentTopic field of waku message (not to be confused with pubsub topic)
  var contentTopic: ContentTopic
  discard ? pb.getField(1, contentTopic)

  ok(HistoryContentFilter(contentTopic: contentTopic))

proc init*(T: type HistoryQuery, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(2, msg.pubsubTopic)

  var buffs: seq[seq[byte]]
  discard ? pb.getRepeatedField(3, buffs)
  
  for buf in buffs:
    msg.contentFilters.add(? HistoryContentFilter.init(buf))

  var pagingInfoBuffer: seq[byte]
  discard ? pb.getField(4, pagingInfoBuffer)

  msg.pagingInfo = ? PagingInfo.init(pagingInfoBuffer)

  var startTime: zint64
  discard ? pb.getField(5, startTime)
  msg.startTime = Timestamp(startTime)

  var endTime: zint64
  discard ? pb.getField(6, endTime)
  msg.endTime = Timestamp(endTime)

  return ok(msg)

proc init*(T: type HistoryResponse, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryResponse()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ? pb.getRepeatedField(2, messages)

  for buf in messages:
    msg.messages.add(? WakuMessage.init(buf))

  var pagingInfoBuffer: seq[byte]
  discard ? pb.getField(3, pagingInfoBuffer)
  msg.pagingInfo= ? PagingInfo.init(pagingInfoBuffer)

  var error: uint32
  discard ? pb.getField(4, error)
  msg.error = HistoryResponseError(error)

  return ok(msg)

proc init*(T: type HistoryRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryRPC()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, rpc.requestId)

  var queryBuffer: seq[byte]
  discard ? pb.getField(2, queryBuffer)

  rpc.query = ? HistoryQuery.init(queryBuffer)

  var responseBuffer: seq[byte]
  discard ? pb.getField(3, responseBuffer)

  rpc.response = ? HistoryResponse.init(responseBuffer)

  return ok(rpc)

proc encode*(filter: HistoryContentFilter): ProtoBuffer =
  var output = initProtoBuffer()
  output.write(1, filter.contentTopic)
  return output

proc encode*(query: HistoryQuery): ProtoBuffer =
  var output = initProtoBuffer()
  
  output.write(2, query.pubsubTopic)

  for filter in query.contentFilters:
    output.write(3, filter.encode())

  output.write(4, query.pagingInfo.encode())

  output.write(5, zint64(query.startTime))
  output.write(6, zint64(query.endTime))

  return output

proc encode*(response: HistoryResponse): ProtoBuffer =
  var output = initProtoBuffer()

  for msg in response.messages:
    output.write(2, msg.encode())

  output.write(3, response.pagingInfo.encode())

  output.write(4, uint32(ord(response.error)))

  return output

proc encode*(rpc: HistoryRPC): ProtoBuffer =
  var output = initProtoBuffer()

  output.write(1, rpc.requestId)
  output.write(2, rpc.query.encode())
  output.write(3, rpc.response.encode())

  return output

proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResponse {.gcsafe.} =
  ## Query history to return a single page of messages matching the query
  
  info "Finding messages matching received query", query=query

  ## Extract query criteria
  ## All query criteria are optional
  let
    qContentTopics = if (query.contentFilters.len != 0): some(query.contentFilters.mapIt(it.contentTopic))
                     else: none(seq[ContentTopic])
    qPubSubTopic = if (query.pubsubTopic != ""): some(query.pubsubTopic)
                   else: none(string)
    qStartTime = if query.startTime != Timestamp(0): some(query.startTime)
                 else: none(Timestamp)
    qEndTime = if query.endTime != Timestamp(0): some(query.endTime)
               else: none(Timestamp)
  
  trace "Combined query criteria into single predicate", contentTopics=qContentTopics, pubsubTopic=qPubSubTopic, startTime=qStartTime, endTime=qEndTime
  
  ## Compose filter predicate for message from query criteria
  proc matchesQuery(indMsg: IndexedWakuMessage): bool =
    trace "Matching indexed message against predicate", msg=indMsg

    if qPubSubTopic.isSome():
      # filter on pubsub topic
      if indMsg.pubsubTopic != qPubSubTopic.get():
        trace "Failed to match pubsub topic", criteria=qPubSubTopic.get(), actual=indMsg.pubsubTopic
        return false
    
    if qStartTime.isSome() and qEndTime.isSome():
      # temporal filtering
      # select only messages whose sender generated timestamps fall bw the queried start time and end time
      
      if indMsg.msg.timestamp > qEndTime.get() or indMsg.msg.timestamp < qStartTime.get():
        trace "Failed to match temporal filter", criteriaStart=qStartTime.get(), criteriaEnd=qEndTime.get(), actual=indMsg.msg.timestamp
        return false
    
    if qContentTopics.isSome():
      # filter on content
      if indMsg.msg.contentTopic notin qContentTopics.get():
        trace "Failed to match content topic", criteria=qContentTopics.get(), actual=indMsg.msg.contentTopic
        return false
    
    return true

  let
    # Read a page of history matching the query
    (wakuMsgList, updatedPagingInfo, error) = w.messages.getPage(matchesQuery, query.pagingInfo)
    # Build response
    historyRes = HistoryResponse(messages: wakuMsgList, pagingInfo: updatedPagingInfo, error: error)
  
  trace "Successfully populated a history response", response=historyRes
  return historyRes

proc init*(ws: WakuStore, capacity = DefaultStoreCapacity) =

  proc handler(conn: Connection, proto: string) {.async.} =
    var message = await conn.readLp(MaxRpcSize.int)
    var res = HistoryRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_store_errors.inc(labelValues = [decodeRpcFailure])
      return

    # TODO Print more info here
    info "received query", rpc=res.value
    waku_store_queries.inc()

    let value = res.value
    let response = ws.findMessages(res.value.query)

    # TODO Do accounting here, response is HistoryResponse
    # How do we get node or swap context?
    if not ws.wakuSwap.isNil:
      info "handle store swap test", text=ws.wakuSwap.text
      # NOTE Perform accounting operation
      let peerId = conn.peerId
      let messages = response.messages
      ws.wakuSwap.credit(peerId, messages.len)
    else:
      info "handle store swap is nil"

    info "sending response", messages=response.messages.len

    await conn.writeLp(HistoryRPC(requestId: value.requestId,
        response: response).encode().buffer)

  ws.handler = handler
  ws.codec = WakuStoreCodec
  ws.messages = StoreQueueRef.new(capacity)

  if ws.store.isNil:
    return

  proc onData(receiverTime: Timestamp, msg: WakuMessage, pubsubTopic:  string) =
    # TODO index should not be recalculated
    discard ws.messages.add(IndexedWakuMessage(msg: msg, index: msg.computeIndex(receiverTime, pubsubTopic), pubsubTopic: pubsubTopic))

  info "attempting to load messages from persistent storage"

  let res = ws.store.getAll(onData)
  if res.isErr:
    warn "failed to load messages from store", err = res.error
    waku_store_errors.inc(labelValues = ["store_load_failure"])
  else:
    info "successfully loaded from store"
  
  debug "the number of messages in the memory", messageNum=ws.messages.len
  waku_store_messages.set(ws.messages.len.int64, labelValues = ["stored"])


proc init*(T: type WakuStore, peerManager: PeerManager, rng: ref BrHmacDrbgContext,
           store: MessageStore = nil, wakuSwap: WakuSwap = nil, persistMessages = true,
           capacity = DefaultStoreCapacity): T =
  debug "init"
  var output = WakuStore(rng: rng, peerManager: peerManager, store: store, wakuSwap: wakuSwap, persistMessages: persistMessages)
  output.init(capacity)
  return output

# @TODO THIS SHOULD PROBABLY BE AN ADD FUNCTION AND APPEND THE PEER TO AN ARRAY
proc setPeer*(ws: WakuStore, peer: RemotePeerInfo) =
  ws.peerManager.addPeer(peer, WakuStoreCodec)
  waku_store_peers.inc()

proc handleMessage*(w: WakuStore, topic: string, msg: WakuMessage) {.async.} =
  if (not w.persistMessages):
    # Store is mounted but new messages should not be stored
    return

  # Handle WakuMessage according to store protocol
  trace "handle message in WakuStore", topic=topic, msg=msg

  let index = msg.computeIndex(pubsubTopic = topic)
  let addRes = w.messages.add(IndexedWakuMessage(msg: msg, index: index, pubsubTopic: topic))
  
  if addRes.isErr:
    trace "Attempt to add message with duplicate index to store", msg=msg, index=index
    waku_store_errors.inc(labelValues = ["duplicate"])
    return # Do not attempt to store in persistent DB
  
  waku_store_messages.set(w.messages.len.int64, labelValues = ["stored"])
  
  if w.store.isNil:
    return

  let res = w.store.put(index, msg, topic)
  if res.isErr:
    trace "failed to store messages", err = res.error
    waku_store_errors.inc(labelValues = ["store_failure"])

proc query*(w: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  # @TODO We need to be more stratigic about which peers we dial. Right now we just set one on the service.
  # Ideally depending on the query and our set  of peers we take a subset of ideal peers.
  # This will require us to check for various factors such as:
  #  - which topics they track
  #  - latency?
  #  - default store peer?

  let peerOpt = w.peerManager.selectPeer(WakuStoreCodec)

  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  let connOpt = await w.peerManager.dialPeer(peerOpt.get(), WakuStoreCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  await connOpt.get().writeLP(HistoryRPC(requestId: generateRequestId(w.rng),
      query: query).encode().buffer)

  var message = await connOpt.get().readLp(MaxRpcSize.int)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])
  handler(response.value.response)

proc queryFrom*(w: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc, peer: RemotePeerInfo): Future[QueryResult] {.async, gcsafe.} =
  ## sends the query to the given peer
  ## returns the number of retrieved messages if no error occurs, otherwise returns the error string
  # TODO dialPeer add it to the list of known peers, while it does not cause any issue but might be unnecessary
  let connOpt = await w.peerManager.dialPeer(peer, WakuStoreCodec)

  if connOpt.isNone():
    error "failed to connect to remote peer"
    waku_store_errors.inc(labelValues = [dialFailure])
    return err("failed to connect to remote peer")

  await connOpt.get().writeLP(HistoryRPC(requestId: generateRequestId(w.rng),
      query: query).encode().buffer)
  debug "query is sent", query=query
  var message = await connOpt.get().readLp(MaxRpcSize.int)
  let response = HistoryRPC.init(message)

  debug "response is received"

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return err("failed to decode response")
    

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])
  handler(response.value.response)
  return ok(response.value.response.messages.len.uint64)

proc queryFromWithPaging*(w: WakuStore, query: HistoryQuery, peer: RemotePeerInfo): Future[MessagesResult] {.async, gcsafe.} =
  ## a thin wrapper for queryFrom
  ## sends the query to the given peer
  ## when the query has a valid pagingInfo, it retrieves the historical messages in pages
  ## returns all the fetched messages if no error occurs, otherwise returns an error string
  debug "queryFromWithPaging is called"
  var messageList: seq[WakuMessage]
  # make a copy of the query
  var q = query
  debug "query is", q=q

  var hasNextPage = true
  proc handler(response: HistoryResponse) {.gcsafe.} =
    # store messages
    for m in response.messages.items: messageList.add(m)
    
    # check whether it is the last page
    hasNextPage = (response.pagingInfo.pageSize != 0)
    debug "hasNextPage", hasNextPage=hasNextPage

    # update paging cursor
    q.pagingInfo.cursor = response.pagingInfo.cursor
    debug "next paging info", pagingInfo=q.pagingInfo

  # fetch the history in pages
  while (hasNextPage):
    let successResult = await w.queryFrom(q, handler, peer)
    if not successResult.isOk: return err("failed to resolve the query")
    debug "hasNextPage", hasNextPage=hasNextPage

  return ok(messageList)

proc queryLoop(w: WakuStore, query: HistoryQuery, candidateList: seq[RemotePeerInfo]): Future[MessagesResult]  {.async, gcsafe.} = 
  ## loops through the candidateList in order and sends the query to each
  ## once all responses have been received, the retrieved messages are consolidated into one deduplicated list
  ## if no messages have been retrieved, the returned future will resolve into a MessagesResult result holding an empty seq.
  var futureList: seq[Future[MessagesResult]]
  for peer in candidateList.items:
    futureList.add(w.queryFromWithPaging(query, peer))
  await allFutures(futureList) # all(), which returns a Future[seq[T]], has been deprecated

  let messagesList = futureList
    .map(proc (fut: Future[MessagesResult]): seq[WakuMessage] =
      if fut.completed() and fut.read().isOk(): # completed() just as a sanity check. These futures have been awaited before using allFutures()
        fut.read().value
      else:
        @[]
    )
    .concat()

  if messagesList.len != 0:
    return ok(messagesList.deduplicate())
  else:
    debug "failed to resolve the query"
    return err("failed to resolve the query")

proc resume*(ws: WakuStore, peerList: Option[seq[RemotePeerInfo]] = none(seq[RemotePeerInfo]), pageSize: uint64 = DefaultPageSize): Future[QueryResult] {.async, gcsafe.} =
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
  

  var currentTime = getNanosecondTime(epochTime())
  debug "resume", currentEpochTime=currentTime

  let lastSeenItem = ws.messages.last()

  var lastSeenTime = if lastSeenItem.isOk(): lastSeenItem.get().msg.timestamp
                     else: Timestamp(0)
                     
  # adjust the time window with an offset of 20 seconds
  let offset: Timestamp = getNanosecondTime(20)
  currentTime = currentTime + offset
  lastSeenTime = max(lastSeenTime - offset, 0)
  debug "the offline time window is", lastSeenTime=lastSeenTime, currentTime=currentTime

  let 
    pinfo = PagingInfo(direction:PagingDirection.FORWARD, pageSize: pageSize)
    rpc = HistoryQuery(pubsubTopic: DefaultTopic, startTime: lastSeenTime, endTime: currentTime, pagingInfo: pinfo)

  var dismissed: uint = 0
  var added: uint = 0
  proc save(msgList: seq[WakuMessage]) =
    debug "save proc is called"
    # exclude index from the comparison criteria

    for msg in msgList:
      let index = msg.computeIndex(pubsubTopic = DefaultTopic)
      # check for duplicate messages
      # TODO Should take pubsub topic into account if we are going to support topics rather than the DefaultTopic
      if ws.messages.contains(index):
        dismissed = dismissed + 1
        continue

      # store the new message 
      let indexedWakuMsg = IndexedWakuMessage(msg: msg, index: index, pubsubTopic: DefaultTopic)
      
      # store in db if exists
      if not ws.store.isNil: 
        let res = ws.store.put(index, msg, DefaultTopic)
        if res.isErr:
          trace "failed to store messages", err = res.error
          waku_store_errors.inc(labelValues = ["store_failure"])
          continue
      
      discard ws.messages.add(indexedWakuMsg)
      added = added + 1
    
    waku_store_messages.set(ws.messages.len.int64, labelValues = ["stored"])

    debug "number of duplicate messages found in resume", dismissed=dismissed
    debug "number of messages added via resume", added=added

  if peerList.isSome:
    debug "trying the candidate list to fetch the history"
    let successResult = await ws.queryLoop(rpc, peerList.get())
    if successResult.isErr:
      debug "failed to resume the history from the list of candidates"
      return err("failed to resume the history from the list of candidates")
    debug "resume is done successfully"
    save(successResult.value)
    return ok(added)
  else:
    debug "no candidate list is provided, selecting a random peer"
    # if no peerList is set then query from one of the peers stored in the peer manager 
    let peerOpt = ws.peerManager.selectPeer(WakuStoreCodec)
    if peerOpt.isNone():
      error "no suitable remote peers"
      waku_store_errors.inc(labelValues = [dialFailure])
      return err("no suitable remote peers")

    debug "a peer is selected from peer manager"
    let remotePeerInfo = peerOpt.get()
    let successResult = await ws.queryFromWithPaging(rpc, remotePeerInfo)
    if successResult.isErr: 
      debug "failed to resume the history"
      return err("failed to resume the history")
    debug "resume is done successfully"
    save(successResult.value)
    return ok(added)

# NOTE: Experimental, maybe incorporate as part of query call
proc queryWithAccounting*(ws: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  # @TODO We need to be more stratigic about which peers we dial. Right now we just set one on the service.
  # Ideally depending on the query and our set  of peers we take a subset of ideal peers.
  # This will require us to check for various factors such as:
  #  - which topics they track
  #  - latency?
  #  - default store peer?

  let peerOpt = ws.peerManager.selectPeer(WakuStoreCodec)

  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  let connOpt = await ws.peerManager.dialPeer(peerOpt.get(), WakuStoreCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  await connOpt.get().writeLP(HistoryRPC(requestId: generateRequestId(ws.rng),
      query: query).encode().buffer)

  var message = await connOpt.get().readLp(MaxRpcSize.int)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return

  # NOTE Perform accounting operation
  # Assumes wakuSwap protocol is mounted
  let remotePeerInfo = peerOpt.get()
  let messages = response.value.response.messages
  ws.wakuSwap.debit(remotePeerInfo.peerId, messages.len)

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])

  handler(response.value.response)
