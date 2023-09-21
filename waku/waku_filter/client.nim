when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, tables, sequtils],
  stew/results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand,
  libp2p/protocols/protocol as libp2p_protocol
import
  ../waku_core,
  ../node/peer_manager,
  ../utils/requests,
  ./rpc,
  ./rpc_codec,
  ./protocol,
  ./protocol_metrics

logScope:
  topics = "waku filter client"


const Defaultstring = "/waku/2/default-waku/proto"

## Client
type WakuFilterClientLegacy* = ref object of LPProtocol
    rng: ref rand.HmacDrbgContext
    peerManager: PeerManager
    subManager: SubscriptionManager


proc handleMessagePush(wf: WakuFilterClientLegacy, peerId: PeerId, requestId: string, rpc: MessagePush) =
  for msg in rpc.messages:
    let
      pubsubTopic = Defaultstring # TODO: Extend the filter push rpc to provide the pubsub topic. This is a limitation
      contentTopic = msg.contentTopic

    wf.subManager.notifySubscriptionHandler(pubsubTopic, contentTopic, msg)


proc initProtocolHandler(wf: WakuFilterClientLegacy) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let buffer = await conn.readLp(MaxRpcSize.int)

    let decodeReqRes = FilterRPC.decode(buffer)
    if decodeReqRes.isErr():
      waku_legacy_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    let rpc = decodeReqRes.get()
    trace "filter message received"

    if rpc.push.isNone():
      waku_legacy_filter_errors.inc(labelValues = [emptyMessagePushFailure])
      # TODO: Manage the empty push message error. Perform any action?
      return

    waku_legacy_filter_messages.inc(labelValues = ["MessagePush"])

    let
      peerId = conn.peerId
      requestId = rpc.requestId
      push = rpc.push.get()

    info "received filter message push", peerId=conn.peerId, requestId=requestId
    wf.handleMessagePush(peerId, requestId, push)

  wf.handler = handle
  wf.codec = WakuLegacyFilterCodec

proc new*(T: type WakuFilterClientLegacy,
          peerManager: PeerManager,
          rng: ref rand.HmacDrbgContext): T =

  let wf = WakuFilterClientLegacy(
      peerManager: peerManager,
      rng: rng,
      subManager: SubscriptionManager.init()
    )
  wf.initProtocolHandler()
  wf


proc sendFilterRpc(wf: WakuFilterClientLegacy, rpc: FilterRPC, peer: PeerId|RemotePeerInfo): Future[WakuFilterResult[void]] {.async, gcsafe.}=
  let connOpt = await wf.peerManager.dialPeer(peer, WakuLegacyFilterCodec)
  if connOpt.isNone():
    return err(dialFailure)
  let connection = connOpt.get()

  await connection.writeLP(rpc.encode().buffer)
  return ok()

proc sendFilterRequestRpc(wf: WakuFilterClientLegacy,
                          pubsubTopic: PubsubTopic,
                          contentTopics: seq[ContentTopic],
                          subscribe: bool,
                          peer: PeerId|RemotePeerInfo): Future[WakuFilterResult[void]] {.async.} =

  let requestId = generateRequestId(wf.rng)
  let contentFilters = contentTopics.mapIt(ContentFilter(contentTopic: it))

  let rpc = FilterRpc(
    requestId: requestId,
    request: some(FilterRequest(
      subscribe: subscribe,
      pubSubTopic: pubsubTopic,
      contentFilters: contentFilters
    ))
  )

  let sendRes = await wf.sendFilterRpc(rpc, peer)
  if sendRes.isErr():
    waku_legacy_filter_errors.inc(labelValues = [sendRes.error])
    return err(sendRes.error)

  return ok()


proc subscribe*(wf: WakuFilterClientLegacy,
                pubsubTopic: PubsubTopic,
                contentTopic: ContentTopic|seq[ContentTopic],
                handler: FilterPushHandler,
                peer: PeerId|RemotePeerInfo): Future[WakuFilterResult[void]] {.async.} =
  var topics: seq[ContentTopic]
  when contentTopic is seq[ContentTopic]:
    topics = contentTopic
  else:
    topics = @[contentTopic]

  let sendRes = await wf.sendFilterRequestRpc(pubsubTopic, topics, subscribe=true, peer=peer)
  if sendRes.isErr():
    return err(sendRes.error)

  for topic in topics:
    wf.subManager.registerSubscription(pubsubTopic, topic, handler)

  return ok()

proc unsubscribe*(wf: WakuFilterClientLegacy,
                  pubsubTopic: PubsubTopic,
                  contentTopic: ContentTopic|seq[ContentTopic],
                  peer: PeerId|RemotePeerInfo): Future[WakuFilterResult[void]] {.async.} =
  var topics: seq[ContentTopic]
  when contentTopic is seq[ContentTopic]:
    topics = contentTopic
  else:
    topics = @[contentTopic]

  let sendRes = await wf.sendFilterRequestRpc(pubsubTopic, topics, subscribe=false, peer=peer)
  if sendRes.isErr():
    return err(sendRes.error)

  # FIXME: I see an issue here that such solution prevents filtering client to properly manage its
  #        subscriptions on different peers and get notified correctly!
  for topic in topics:
    wf.subManager.removeSubscription(pubsubTopic, topic)

  return ok()

proc clearSubscriptions*(wf: WakuFilterClientLegacy) =
  wf.subManager.clear()

proc getSubscriptionsCount*(wf: WakuFilterClientLegacy): int =
  wf.subManager.getSubscriptionsCount()
