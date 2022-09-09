import
  std/[options, sets, tables, sequtils],
  stew/results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand,
  libp2p/protocols/protocol,
  libp2p/crypto/crypto
import
  ../waku_message,
  ../../node/peer_manager/peer_manager,
  ../../utils/requests,
  ./rpc,
  ./rpc_codec


declarePublicGauge waku_filter_peers, "number of filter peers"
declarePublicGauge waku_filter_subscribers, "number of light node filter subscribers"
declarePublicGauge waku_filter_errors, "number of filter protocol errors", ["type"]
declarePublicGauge waku_filter_messages, "number of filter messages received", ["type"]

logScope:
  topics = "wakufilter"


const
  # We add a 64kB safety buffer for protocol overhead.
  # 10x-multiplier also for safety: currently we never
  # push more than 1 message at a time.
  MaxRpcSize* = 10 * MaxWakuMessageSize + 64 * 1024

  WakuFilterCodec* = "/vac/waku/filter/2.0.0-beta1"
  WakuFilterTimeout: Duration = 2.hours


# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"
  peerNotFoundFailure = "peer_not_found_failure"


type Subscription = object
  requestId: string
  peer: PeerID
  pubsubTopic: string
  contentTopics: HashSet[ContentTopic]


proc addSubscription(subscriptions: var seq[Subscription], peer: PeerID, requestId: string, pubsubTopic: string, contentTopics: seq[ContentTopic]) =
  let subscription = Subscription(
    requestId: requestId,
    peer: peer,
    pubsubTopic: pubsubTopic,
    contentTopics: toHashSet(contentTopics)
  )
  subscriptions.add(subscription)

proc removeSubscription(subscriptions: var seq[Subscription], peer: PeerId, unsubscribeTopics: seq[ContentTopic]) =
  for sub in subscriptions.mitems:
    if sub.peer != peer: 
      continue
    
    sub.contentTopics.excl(toHashSet(unsubscribeTopics))

  # Delete the subscriber if no more content filters left
  subscriptions.keepItIf(it.contentTopics.len > 0)


type
  MessagePushHandler* = proc(requestId: string, msg: MessagePush): Future[void] {.gcsafe, closure.}

  WakuFilterResult*[T] = Result[T, string]  

  WakuFilter* = ref object of LPProtocol
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager
    pushHandler*: MessagePushHandler
    subscriptions*: seq[Subscription]
    failedPeers*: Table[string, chronos.Moment]
    timeout*: chronos.Duration

proc init(wf: WakuFilter) =

  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let message = await conn.readLp(MaxRpcSize.int)

    let res = FilterRPC.init(message)
    if res.isErr():
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    trace "filter message received"
    
    let rpc = res.get()

    ## Filter request
    # We are receiving a subscription/unsubscription request
    if rpc.request != FilterRequest():
      waku_filter_messages.inc(labelValues = ["FilterRequest"])

      let 
        requestId = rpc.requestId
        subscribe = rpc.request.subscribe
        pubsubTopic =  rpc.request.pubsubTopic
        contentTopics = rpc.request.contentFilters.mapIt(it.contentTopic)

      if subscribe:
        info "added filter subscritpiton", peerId=conn.peerId, pubsubTopic=pubsubTopic, contentTopics=contentTopics
        wf.subscriptions.addSubscription(conn.peerId, requestId, pubsubTopic, contentTopics)
      else:
        info "removed filter subscritpiton", peerId=conn.peerId, contentTopics=contentTopics
        wf.subscriptions.removeSubscription(conn.peerId, contentTopics)

      waku_filter_subscribers.set(wf.subscriptions.len.int64)
      
    
    ## Push message
    # We are receiving a messages from the peer that we subscribed to
    if rpc.push != MessagePush():
      waku_filter_messages.inc(labelValues = ["MessagePush"])
      
      let
        requestId = rpc.requestId 
        push = rpc.push

      info "received filter message push", peerId=conn.peerId
      await wf.pushHandler(requestId, push)


  wf.handler = handle
  wf.codec = WakuFilterCodec

proc init*(T: type WakuFilter, 
           peerManager: PeerManager, 
           rng: ref rand.HmacDrbgContext, 
           handler: MessagePushHandler,
           timeout: Duration = WakuFilterTimeout): T =
  let wf = WakuFilter(rng: rng,
                      peerManager: peerManager, 
                      pushHandler: handler,
                      timeout: timeout)
  wf.init()
  return wf


proc setPeer*(wf: WakuFilter, peer: RemotePeerInfo) =
  wf.peerManager.addPeer(peer, WakuFilterCodec)
  waku_filter_peers.inc()
  

proc sendFilterRpcToPeer(wf: WakuFilter, rpc: FilterRPC, peer: PeerId): Future[WakuFilterResult[void]] {.async, gcsafe.}=
  let connOpt = await wf.peerManager.dialPeer(peer, WakuFilterCodec)
  if connOpt.isNone():
    return err(dialFailure)

  let connection = connOpt.get()

  await connection.writeLP(rpc.encode().buffer)

  return ok()

proc sendFilterRpcToRemotePeer(wf: WakuFilter, rpc: FilterRPC, peer: RemotePeerInfo): Future[WakuFilterResult[void]] {.async, gcsafe.}=
  let connOpt = await wf.peerManager.dialPeer(peer, WakuFilterCodec)
  if connOpt.isNone():
    return err(dialFailure)

  let connection = connOpt.get()

  await connection.writeLP(rpc.encode().buffer)

  return ok()


### Send message to subscriptors
proc removePeerFromFailedPeersTable(wf: WakuFilter, subs: seq[Subscription]) = 
  ## Clear the failed peer table if subscriber was able to connect
  for sub in subs:
    wf.failedPeers.del($sub)

proc handleClientError(wf: WakuFilter, subs: seq[Subscription]) {.raises: [Defect, KeyError].} = 
  ## If we have already failed to send message to this peer,
  ## check for elapsed time and if it's been too long, remove the peer.
  for sub in subs:
    let subKey: string = $(sub)
    
    if not wf.failedPeers.hasKey(subKey):
      # add the peer to the failed peers table.
      wf.failedPeers[subKey] = Moment.now() 
      return

    let elapsedTime = Moment.now() - wf.failedPeers[subKey]
    if elapsedTime > wf.timeout:
      wf.failedPeers.del(subKey)

      let index = wf.subscriptions.find(sub)
      wf.subscriptions.delete(index)


proc handleMessage*(wf: WakuFilter, pubsubTopic: string, msg: WakuMessage) {.async.} =
  if wf.subscriptions.len <= 0:
    return

  var failedSubscriptions: seq[Subscription]
  var connectedSubscriptions: seq[Subscription]

  for sub in wf.subscriptions:
    # TODO: Review when pubsubTopic can be empty and if it is a valid case
    if sub.pubSubTopic != "" and sub.pubSubTopic != pubsubTopic:
      continue

    if msg.contentTopic notin sub.contentTopics:
      continue

    let rpc = FilterRPC(
      requestId: sub.requestId,
      push: MessagePush(messages: @[msg])
    )

    let res = await wf.sendFilterRpcToPeer(rpc, sub.peer)
    if res.isErr():
      waku_filter_errors.inc(labelValues = [res.error()])
      failedSubscriptions.add(sub)
      continue
      
    connectedSubscriptions.add(sub)

  wf.removePeerFromFailedPeersTable(connectedSubscriptions)

  wf.handleClientError(failedSubscriptions)


### Send subscription/unsubscription

proc subscribe(wf: WakuFilter, pubsubTopic: string, contentTopics: seq[ContentTopic], peer: RemotePeerInfo): Future[WakuFilterResult[string]] {.async, gcsafe.} =
  let id = generateRequestId(wf.rng)
  let rpc = FilterRPC(
    requestId: id,
    request: FilterRequest(
      subscribe: true,
      pubSubTopic: pubsubTopic,
      contentFilters: contentTopics.mapIt(ContentFilter(contentTopic: it))
    )
  )

  let res = await wf.sendFilterRpcToRemotePeer(rpc, peer)
  if res.isErr():
    waku_filter_errors.inc(labelValues = [res.error()])
    return err(res.error())
    
  return ok(id)

proc subscribe*(wf: WakuFilter, pubsubTopic: string, contentTopics: seq[ContentTopic]): Future[WakuFilterResult[string]] {.async, gcsafe.} =
  let peerOpt = wf.peerManager.selectPeer(WakuFilterCodec)
  if peerOpt.isNone():
    waku_filter_errors.inc(labelValues = [peerNotFoundFailure])
    return err(peerNotFoundFailure)

  return await wf.subscribe(pubsubTopic, contentTopics, peerOpt.get())


proc unsubscribe(wf: WakuFilter, pubsubTopic: string, contentTopics: seq[ContentTopic], peer: RemotePeerInfo): Future[WakuFilterResult[void]] {.async, gcsafe.} =
  let id = generateRequestId(wf.rng)
  let rpc = FilterRPC(
    requestId: id, 
    request: FilterRequest(
      subscribe: false,
      pubSubTopic: pubsubTopic,
      contentFilters: contentTopics.mapIt(ContentFilter(contentTopic: it))
    )
  )

  let res = await wf.sendFilterRpcToRemotePeer(rpc, peer)
  if res.isErr():
    waku_filter_errors.inc(labelValues = [res.error()])
    return err(res.error())

  return ok()

proc unsubscribe*(wf: WakuFilter, pubsubTopic: string, contentTopics: seq[ContentTopic]): Future[WakuFilterResult[void]] {.async, gcsafe.} =
  let peerOpt = wf.peerManager.selectPeer(WakuFilterCodec)
  if peerOpt.isNone():
    waku_filter_errors.inc(labelValues = [peerNotFoundFailure])
    return err(peerNotFoundFailure)

  return await wf.unsubscribe(pubsubTopic, contentTopics, peerOpt.get())