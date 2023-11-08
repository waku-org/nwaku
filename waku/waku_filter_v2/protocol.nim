## Waku Filter protocol for subscribing and filtering messages

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options,sequtils,sets,strutils,tables],
  stew/byteutils,
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/protocol
import
  ../node/peer_manager,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc_codec,
  ./rpc,
  ./subscriptions

logScope:
  topics = "waku filter"

const
  MaxContentTopicsPerRequest* = 30

type
  WakuFilter* = ref object of LPProtocol
    subscriptions*: FilterSubscriptions # a mapping of peer ids to a sequence of filter criteria
    peerManager: PeerManager
    maintenanceTask: TimerCallback

proc pingSubscriber(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  trace "pinging subscriber", peerId=peerId

  if peerId notin wf.subscriptions:
    debug "pinging peer has no subscriptions", peerId=peerId
    return err(FilterSubscribeError.notFound())

  ok()

proc subscribe(wf: WakuFilter, peerId: PeerID, pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic]): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.len() == 0:
    return err(FilterSubscribeError.badRequest("pubsubTopic and contentTopics must be specified"))

  if contentTopics.len() > MaxContentTopicsPerRequest:
    return err(FilterSubscribeError.badRequest("exceeds maximum content topics: " & $MaxContentTopicsPerRequest))

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  trace "subscribing peer to filter criteria", peerId=peerId, filterCriteria=filterCriteria

  if peerId in wf.subscriptions:
    # We already have a subscription for this peer. Try to add the new filter criteria.
    var peerSubscription = wf.subscriptions.mgetOrPut(peerId, initHashSet[FilterCriterion]())
    if peerSubscription.len() + filterCriteria.len() > MaxCriteriaPerSubscription:
      return err(FilterSubscribeError.serviceUnavailable("peer has reached maximum number of filter criteria"))

    peerSubscription.incl(filterCriteria)
    wf.subscriptions[peerId] = peerSubscription
  else:
    # We don't have a subscription for this peer yet. Try to add it.
    if wf.subscriptions.len() >= MaxTotalSubscriptions:
      return err(FilterSubscribeError.serviceUnavailable("node has reached maximum number of subscriptions"))
    debug "creating new subscription", peerId=peerId
    wf.subscriptions[peerId] = filterCriteria

  ok()

proc unsubscribe(wf: WakuFilter, peerId: PeerID, pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic]): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.len() == 0:
    return err(FilterSubscribeError.badRequest("pubsubTopic and contentTopics must be specified"))

  if contentTopics.len() > MaxContentTopicsPerRequest:
    return err(FilterSubscribeError.badRequest("exceeds maximum content topics: " & $MaxContentTopicsPerRequest))

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  trace "unsubscribing peer from filter criteria", peerId=peerId, filterCriteria=filterCriteria

  if peerId notin wf.subscriptions:
    debug "unsubscribing peer has no subscriptions", peerId=peerId
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
    debug "unsubscribing peer has no subscriptions", peerId=peerId
    return err(FilterSubscribeError.notFound())

  debug "removing peer subscription", peerId=peerId
  wf.subscriptions.del(peerId)

  ok()

proc handleSubscribeRequest*(wf: WakuFilter, peerId: PeerId, request: FilterSubscribeRequest): FilterSubscribeResponse =
  info "received filter subscribe request", peerId=peerId, request=request
  waku_filter_requests.inc(labelValues = [$request.filterSubscribeType])

  var subscribeResult: FilterSubscribeResult

  let requestStartTime = Moment.now()

  block:
    ## Handle subscribe request
    case request.filterSubscribeType
    of FilterSubscribeType.SUBSCRIBER_PING:
      subscribeResult = wf.pingSubscriber(peerId)
    of FilterSubscribeType.SUBSCRIBE:
      subscribeResult = wf.subscribe(peerId, request.pubsubTopic, request.contentTopics)
    of FilterSubscribeType.UNSUBSCRIBE:
      subscribeResult = wf.unsubscribe(peerId, request.pubsubTopic, request.contentTopics)
    of FilterSubscribeType.UNSUBSCRIBE_ALL:
      subscribeResult = wf.unsubscribeAll(peerId)

  let
    requestDuration = Moment.now() - requestStartTime
    requestDurationSec = requestDuration.milliseconds.float / 1000  # Duration in seconds with millisecond precision floating point
  waku_filter_request_duration_seconds.observe(requestDurationSec, labelValues = [$request.filterSubscribeType])

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
  debug "pushing message to subscribed peers", pubsubTopic=messagePush.pubsubTopic, contentTopic=messagePush.wakuMessage.contentTopic, peers=peers, hash=messagePush.pubsubTopic.computeMessageHash(messagePush.wakuMessage).to0xHex()

  let bufferToPublish = messagePush.encode().buffer

  var pushFuts: seq[Future[void]]
  for peerId in peers:
    let pushFut = wf.pushToPeer(peerId, bufferToPublish)
    pushFuts.add(pushFut)

  await allFutures(pushFuts)

proc maintainSubscriptions*(wf: WakuFilter) =
  trace "maintaining subscriptions"

  ## Remove subscriptions for peers that have been removed from peer store
  var peersToRemove: seq[PeerId]
  for peerId, peerSubscription in wf.subscriptions.pairs():
    ## TODO: currently we only maintain by syncing with peer store. We could
    ## consider other metrics, such as subscription age, activity, etc.
    if not wf.peerManager.peerStore.hasPeer(peerId, WakuFilterPushCodec):
      debug "peer has been removed from peer store, removing subscription", peerId=peerId
      peersToRemove.add(peerId)

  if peersToRemove.len() > 0:
    wf.subscriptions.removePeers(peersToRemove)

  ## Periodic report of number of subscriptions
  waku_filter_subscriptions.set(wf.subscriptions.len().float64)

const MessagePushTimeout = 20.seconds
proc handleMessage*(wf: WakuFilter, pubsubTopic: PubsubTopic, message: WakuMessage) {.async.} =
  trace "handling message", pubsubTopic=pubsubTopic, message=message

  let handleMessageStartTime = Moment.now()

  block:
    ## Find subscribers and push message to them
    let subscribedPeers = wf.subscriptions.findSubscribedPeers(pubsubTopic, message.contentTopic)
    if subscribedPeers.len() == 0:
      trace "no subscribed peers found", pubsubTopic=pubsubTopic, contentTopic=message.contentTopic
      return

    let messagePush = MessagePush(
          pubsubTopic: pubsubTopic,
          wakuMessage: message)

    if not await wf.pushToPeers(subscribedPeers, messagePush).withTimeout(MessagePushTimeout):
      debug "timed out pushing message to peers", pubsubTopic=pubsubTopic, contentTopic=message.contentTopic, hash=pubsubTopic.computeMessageHash(message).to0xHex()
      waku_filter_errors.inc(labelValues = [pushTimeoutFailure])
    else:
      debug "pushed message succesfully to all subscribers", pubsubTopic=pubsubTopic, contentTopic=message.contentTopic, hash=pubsubTopic.computeMessageHash(message).to0xHex()


  let
    handleMessageDuration = Moment.now() - handleMessageStartTime
    handleMessageDurationSec = handleMessageDuration.milliseconds.float / 1000  # Duration in seconds with millisecond precision floating point
  waku_filter_handle_message_duration_seconds.observe(handleMessageDurationSec)

proc initProtocolHandler(wf: WakuFilter) =

  proc handler(conn: Connection, proto: string) {.async.} =
    trace "filter subscribe request handler triggered", peerId=conn.peerId

    let buf = await conn.readLp(MaxSubscribeSize)

    let decodeRes = FilterSubscribeRequest.decode(buf)
    if decodeRes.isErr():
      error "Failed to decode filter subscribe request", peerId=conn.peerId, err=decodeRes.error
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    let request = decodeRes.value #TODO: toAPI() split here

    let response = wf.handleSubscribeRequest(conn.peerId, request)

    debug "sending filter subscribe response", peerId=conn.peerId, response=response

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
  var maintainSubs: CallbackFunc
  maintainSubs = CallbackFunc(
    proc(udata: pointer) {.gcsafe.} =
      maintainSubscriptions(wf)
      wf.maintenanceTask = setTimer(Moment.fromNow(interval), maintainSubs)
  )

  wf.maintenanceTask = setTimer(Moment.fromNow(interval), maintainSubs)

method start*(wf: WakuFilter) {.async.} =
  debug "starting filter protocol"
  wf.startMaintainingSubscriptions(MaintainSubscriptionsInterval)

  await procCall LPProtocol(wf).start()

method stop*(wf: WakuFilter) {.async.} =
  debug "stopping filter protocol"
  if not wf.maintenanceTask.isNil():
    wf.maintenanceTask.clearTimer()
  await procCall LPProtocol(wf).stop()
