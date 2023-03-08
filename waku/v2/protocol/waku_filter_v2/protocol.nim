## Waku Filter protocol for subscribing and filtering messages

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options,sequtils,sets,tables],
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/protocol
import
  ../../node/peer_manager,
  ../waku_message,
  ./common,
  ./protocol_metrics,
  ./rpc_codec,
  ./rpc,
  ./subscriptions

logScope:
  topics = "waku filter"

type
  WakuFilter* = ref object of LPProtocol
    subscriptions*: FilterSubscriptions # a mapping of peer ids to a sequence of filter criteria
    peerManager: PeerManager

proc pingSubscriber(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  trace "pinging subscriber", peerId=peerId

  if peerId notin wf.subscriptions:
    debug "pinging peer has no subscriptions", peerId=peerId
    return err(FilterSubscribeError.notFound())

  ok()

proc subscribe(wf: WakuFilter, peerId: PeerID, pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic]): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.len() == 0:
    return err(FilterSubscribeError.badRequest("pubsubTopic and contentTopics must be specified"))

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  trace "subscribing peer to filter criteria", peerId=peerId, filterCriteria=filterCriteria

  if peerId in wf.subscriptions:
    var peerSubscription = wf.subscriptions.mgetOrPut(peerId, initHashSet[FilterCriterion]())
    if peerSubscription.len() + filterCriteria.len() >= MaxCriteriaPerSubscription:
      return err(FilterSubscribeError.serviceUnavailable("peer has reached maximum number of filter criteria"))

    peerSubscription.incl(filterCriteria)
    wf.subscriptions[peerId] = peerSubscription
  else:
    if wf.subscriptions.len() >= MaxTotalSubscriptions:
      return err(FilterSubscribeError.serviceUnavailable("node has reached maximum number of subscriptions"))
    debug "creating new subscription", peerId=peerId
    wf.subscriptions[peerId] = filterCriteria

  ok()

proc unsubscribe(wf: WakuFilter, peerId: PeerID, pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic]): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.len() == 0:
    return err(FilterSubscribeError.badRequest("pubsubTopic and contentTopics must be specified"))

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  trace "unsubscribing peer from filter criteria", peerId=peerId, filterCriteria=filterCriteria

  if peerId notin wf.subscriptions:
    debug "unsubscibing peer has no subscriptions", peerId=peerId
    return err(FilterSubscribeError.notFound())

  var peerSubscription = wf.subscriptions.mgetOrPut(peerId, initHashSet[FilterCriterion]())
  # TODO: consider error response if filter criteria does not exist
  peerSubscription.excl(filterCriteria)

  if peerSubscription.len() == 0:
    debug "peer has no more subscriptions, removing subscription", peerId=peerId
    wf.subscriptions.del(peerId)
  else:
    wf.subscriptions[peerId] = peerSubscription

  ok()

proc unsubscribeAll(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  if peerId notin wf.subscriptions:
    debug "unsubscibing peer has no subscriptions", peerId=peerId
    return err(FilterSubscribeError.notFound())

  debug "removing peer subscription", peerId=peerId
  wf.subscriptions.del(peerId)

  ok()

proc handleSubscribeRequest*(wf: WakuFilter, peerId: PeerId, request: FilterSubscribeRequest): FilterSubscribeResponse =
  info "received filter subscribe request", peerId=peerId, request=request
  waku_filter_requests.inc(labelValues = [$request.filterSubscribeType])

  var subscribeResult: FilterSubscribeResult

  case request.filterSubscribeType
  of FilterSubscribeType.SUBSCRIBER_PING:
    subscribeResult = wf.pingSubscriber(peerId)
  of FilterSubscribeType.SUBSCRIBE:
    subscribeResult = wf.subscribe(peerId, request.pubsubTopic, request.contentTopics)
  of FilterSubscribeType.UNSUBSCRIBE:
    subscribeResult = wf.unsubscribe(peerId, request.pubsubTopic, request.contentTopics)
  of FilterSubscribeType.UNSUBSCRIBE_ALL:
    subscribeResult = wf.unsubscribeAll(peerId)

  if subscribeResult.isErr():
    return FilterSubscribeResponse(
      requestId: request.requestId,
      statusCode: subscribeResult.error.kind.uint32,
      statusDesc: some($subscribeResult.error)
    )
  else:
    return FilterSubscribeResponse.ok(request.requestId)

proc pushToPeer(wf: WakuFilter, peer: PeerId, buffer: seq[byte]) {.async.} =
  trace "pushing message to subscribed peer", peer=peer

  if not wf.peerManager.peerStore.hasPeer(peer, WakuFilterPushCodec):
    # Check that peer has not been removed from peer store
    trace "no addresses for peer", peer=peer
    return

  let conn = await wf.peerManager.dialPeer(peer, WakuFilterPushCodec)
  if conn.isNone():
    ## We do not remove this peer, but allow the underlying peer manager
    ## to do so if it is deemed necessary
    trace "no connection to peer", peer=peer
    return

  await conn.get().writeLp(buffer)

proc pushToPeers(wf: WakuFilter, peers: seq[PeerId], messagePush: MessagePush) {.async.} =
  trace "pushing message to subscribed peers", peers=peers, messagePush=messagePush

  let bufferToPublish = messagePush.encode().buffer

  var pushFuts: seq[Future[void]]
  for peerId in peers:
    let pushFut = wf.pushToPeer(peerId, bufferToPublish)
    pushFuts.add(pushFut)

  await allFutures(pushFuts)

proc maintainSubscriptions*(wf: WakuFilter) =
  trace "maintaining subscriptions"

  var peersToRemove: seq[PeerId]
  for peerId, peerSubscription in wf.subscriptions.pairs():
    ## TODO: currently we only maintain by syncing with peer store. We could
    ## consider other metrics, such as subscription age, activity, etc.
    if not wf.peerManager.peerStore.hasPeer(peerId, WakuFilterPushCodec):
      debug "peer has been removed from peer store, removing subscription", peerId=peerId
      peersToRemove.add(peerId)

  wf.subscriptions.removePeers(peersToRemove)

proc handleMessage*(wf: WakuFilter, pubsubTopic: PubsubTopic, message: WakuMessage) {.async.} =
  trace "handling message", pubsubTopic=pubsubTopic, message=message

  let subscribedPeers = wf.subscriptions.findSubscribedPeers(pubsubTopic, message.contentTopic)
  if subscribedPeers.len() == 0:
    trace "no subscribed peers found", pubsubTopic=pubsubTopic, contentTopic=message.contentTopic
    return

  let messagePush = MessagePush(
        pubsubTopic: pubsubTopic,
        wakuMessage: message)

  await wf.pushToPeers(subscribedPeers, messagePush)

proc initProtocolHandler(wf: WakuFilter) =

  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(MaxSubscribeSize)

    let decodeRes = FilterSubscribeRequest.decode(buf)
    if decodeRes.isErr():
      error "Failed to decode filter subscribe request", peerId=conn.peerId
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    let request = decodeRes.value #TODO: toAPI() split here

    let response = wf.handleSubscribeRequest(conn.peerId, request)

    await conn.writeLp(response.encode().buffer) #TODO: toRPC() separation here
    return

  wf.handler = handler
  wf.codec = WakuFilterSubscribeCodec

proc new*(T: type WakuFilter,
          peerManager: PeerManager): T =

  let wf = WakuFilter(
    peerManager: peerManager
  )
  wf.initProtocolHandler()
  wf

const MaintainSubscriptionsInterval* = 1.minutes

proc startMaintainingSubscriptions*(wf: WakuFilter, interval: Duration) =
  trace "starting to maintain subscriptions"
  var maintainSubs: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  maintainSubs = proc(udata: pointer) {.gcsafe.} =
    maintainSubscriptions(wf)
    discard setTimer(Moment.fromNow(interval), maintainSubs)

  discard setTimer(Moment.fromNow(interval), maintainSubs)

method start*(wf: WakuFilter) {.async.} =
  debug "starting filter protocol"
  wf.startMaintainingSubscriptions(MaintainSubscriptionsInterval)

  await procCall LPProtocol(wf).start()

method stop*(wf: WakuFilter) {.async.} =
  debug "stopping filter protocol"
  await procCall LPProtocol(wf).stop()
