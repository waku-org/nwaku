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
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics


logScope:
  topics = "waku filter"


const
  WakuFilterCodec* = "/vac/waku/filter/2.0.0-beta1"

  WakuFilterTimeout: Duration = 2.hours


type WakuFilterResult*[T] = Result[T, string]  


## Subscription manager

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


## Protocol

type
  MessagePushHandler* = proc(requestId: string, msg: MessagePush): Future[void] {.gcsafe, closure.}

  WakuFilter* = ref object of LPProtocol
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager
    subscriptions*: seq[Subscription]
    failedPeers*: Table[string, chronos.Moment]
    timeout*: chronos.Duration

proc handleFilterRequest(wf: WakuFilter, peerId: PeerId, rpc: FilterRPC) =
  let 
    requestId = rpc.requestId
    subscribe = rpc.request.subscribe
    pubsubTopic =  rpc.request.pubsubTopic
    contentTopics = rpc.request.contentFilters.mapIt(it.contentTopic)

  if subscribe:
    info "added filter subscritpiton", peerId=peerId, pubsubTopic=pubsubTopic, contentTopics=contentTopics
    wf.subscriptions.addSubscription(peerId, requestId, pubsubTopic, contentTopics)
  else:
    info "removed filter subscritpiton", peerId=peerId, contentTopics=contentTopics
    wf.subscriptions.removeSubscription(peerId, contentTopics)

  waku_filter_subscribers.set(wf.subscriptions.len.int64)


proc initProtocolHandler(wf: WakuFilter) =
  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let buffer = await conn.readLp(MaxRpcSize.int)

    let decodeRpcRes = FilterRPC.decode(buffer)
    if decodeRpcRes.isErr():
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    trace "filter message received"
    
    let rpc = decodeRpcRes.get()

    ## Filter request
    # Subscription/unsubscription request
    if rpc.request == FilterRequest():
      waku_filter_errors.inc(labelValues = [emptyFilterRequestFailure])
      # TODO: Manage the empty filter request message error. Perform any action?
      return

    waku_filter_messages.inc(labelValues = ["FilterRequest"])
    wf.handleFilterRequest(conn.peerId, rpc) 
    
  wf.handler = handler
  wf.codec = WakuFilterCodec

proc new*(T: type WakuFilter, 
           peerManager: PeerManager, 
           rng: ref rand.HmacDrbgContext, 
           timeout: Duration = WakuFilterTimeout): T =
  let wf = WakuFilter(rng: rng,
                      peerManager: peerManager, 
                      timeout: timeout)
  wf.initProtocolHandler()
  return wf

proc init*(T: type WakuFilter, 
           peerManager: PeerManager, 
           rng: ref rand.HmacDrbgContext, 
           timeout: Duration = WakuFilterTimeout): T {.
  deprecated: "WakuFilter.new()' instead".} =
  WakuFilter.new(peerManager, rng, timeout)


proc sendFilterRpc(wf: WakuFilter, rpc: FilterRPC, peer: PeerId|RemotePeerInfo): Future[WakuFilterResult[void]] {.async, gcsafe.}=
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
  
  trace "handling message", pubsubTopic, contentTopic=msg.contentTopic, subscriptions=wf.subscriptions.len

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

    let res = await wf.sendFilterRpc(rpc, sub.peer)
    if res.isErr():
      waku_filter_errors.inc(labelValues = [res.error()])
      failedSubscriptions.add(sub)
      continue

    connectedSubscriptions.add(sub)

  wf.removePeerFromFailedPeersTable(connectedSubscriptions)

  wf.handleClientError(failedSubscriptions)
