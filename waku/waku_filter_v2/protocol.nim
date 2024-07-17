## Waku Filter protocol for subscribing and filtering messages

{.push raises: [].}

import
  std/[options, sequtils, sets, strutils, tables],
  stew/byteutils,
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/protocol,
  libp2p/protocols/pubsub/timedcache
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

const MaxContentTopicsPerRequest* = 100

type WakuFilter* = ref object of LPProtocol
  subscriptions*: FilterSubscriptions
    # a mapping of peer ids to a sequence of filter criteria
  peerManager: PeerManager
  maintenanceTask: TimerCallback
  messageCache: TimedCache[string]

proc pingSubscriber(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  trace "pinging subscriber", peerId = peerId

  if not wf.subscriptions.isSubscribed(peerId):
    debug "pinging peer has no subscriptions", peerId = peerId
    return err(FilterSubscribeError.notFound())

  wf.subscriptions.refreshSubscription(peerId)

  ok()

proc subscribe(
    wf: WakuFilter,
    peerId: PeerID,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
): FilterSubscribeResult =
  # TODO: check if this condition is valid???
  if pubsubTopic.isNone() or contentTopics.len == 0:
    return err(
      FilterSubscribeError.badRequest("pubsubTopic and contentTopics must be specified")
    )

  if contentTopics.len > MaxContentTopicsPerRequest:
    return err(
      FilterSubscribeError.badRequest(
        "exceeds maximum content topics: " & $MaxContentTopicsPerRequest
      )
    )

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  trace "subscribing peer to filter criteria",
    peerId = peerId, filterCriteria = filterCriteria

  wf.subscriptions.addSubscription(peerId, filterCriteria).isOkOr:
    return err(FilterSubscribeError.serviceUnavailable(error))

  ok()

proc unsubscribe(
    wf: WakuFilter,
    peerId: PeerID,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.len == 0:
    return err(
      FilterSubscribeError.badRequest("pubsubTopic and contentTopics must be specified")
    )

  if contentTopics.len > MaxContentTopicsPerRequest:
    return err(
      FilterSubscribeError.badRequest(
        "exceeds maximum content topics: " & $MaxContentTopicsPerRequest
      )
    )

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  debug "unsubscribing peer from filter criteria",
    peerId = peerId, filterCriteria = filterCriteria

  wf.subscriptions.removeSubscription(peerId, filterCriteria).isOkOr:
    return err(FilterSubscribeError.notFound())

  ok()

proc unsubscribeAll(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  if not wf.subscriptions.isSubscribed(peerId):
    debug "unsubscribing peer has no subscriptions", peerId = peerId
    return err(FilterSubscribeError.notFound())

  debug "removing peer subscription", peerId = peerId
  wf.subscriptions.removePeer(peerId)
  wf.subscriptions.cleanUp()

  ok()

proc handleSubscribeRequest*(
    wf: WakuFilter, peerId: PeerId, request: FilterSubscribeRequest
): FilterSubscribeResponse =
  info "received filter subscribe request", peerId = peerId, request = request
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
      subscribeResult =
        wf.unsubscribe(peerId, request.pubsubTopic, request.contentTopics)
    of FilterSubscribeType.UNSUBSCRIBE_ALL:
      subscribeResult = wf.unsubscribeAll(peerId)

  let
    requestDuration = Moment.now() - requestStartTime
    requestDurationSec = requestDuration.milliseconds.float / 1000
      # Duration in seconds with millisecond precision floating point
  waku_filter_request_duration_seconds.observe(
    requestDurationSec, labelValues = [$request.filterSubscribeType]
  )

  if subscribeResult.isErr():
    return FilterSubscribeResponse(
      requestId: request.requestId,
      statusCode: subscribeResult.error.kind.uint32,
      statusDesc: some($subscribeResult.error),
    )
  else:
    return FilterSubscribeResponse.ok(request.requestId)

proc pushToPeer(wf: WakuFilter, peer: PeerId, buffer: seq[byte]) {.async.} =
  trace "pushing message to subscribed peer", peer_id = shortLog(peer)

  if not wf.peerManager.peerStore.hasPeer(peer, WakuFilterPushCodec):
    # Check that peer has not been removed from peer store
    error "no addresses for peer", peer_id = shortLog(peer)
    return

  ## TODO: Check if dial is necessary always???
  let conn = await wf.peerManager.dialPeer(peer, WakuFilterPushCodec)
  if conn.isNone():
    ## We do not remove this peer, but allow the underlying peer manager
    ## to do so if it is deemed necessary
    error "no connection to peer", peer_id = shortLog(peer)
    return

  await conn.get().writeLp(buffer)

proc pushToPeers(
    wf: WakuFilter, peers: seq[PeerId], messagePush: MessagePush
) {.async.} =
  let targetPeerIds = peers.mapIt(shortLog(it))
  let msgHash =
    messagePush.pubsubTopic.computeMessageHash(messagePush.wakuMessage).to0xHex()

  ## it's also refresh expire of msghash, that's why update cache every time, even if it has a value.
  if wf.messageCache.put(msgHash, Moment.now()):
    notice "duplicate message found, not-pushing message to subscribed peers",
      pubsubTopic = messagePush.pubsubTopic,
      contentTopic = messagePush.wakuMessage.contentTopic,
      target_peer_ids = targetPeerIds,
      msg_hash = msgHash
  else:
    notice "pushing message to subscribed peers",
      pubsubTopic = messagePush.pubsubTopic,
      contentTopic = messagePush.wakuMessage.contentTopic,
      target_peer_ids = targetPeerIds,
      msg_hash = msgHash

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
  for peerId in wf.subscriptions.peersSubscribed.keys:
    if not wf.peerManager.peerStore.hasPeer(peerId, WakuFilterPushCodec):
      debug "peer has been removed from peer store, removing subscription",
        peerId = peerId
      peersToRemove.add(peerId)

  if peersToRemove.len > 0:
    wf.subscriptions.removePeers(peersToRemove)

  wf.subscriptions.cleanUp()

  ## Periodic report of number of subscriptions
  waku_filter_subscriptions.set(wf.subscriptions.peersSubscribed.len.float64)

const MessagePushTimeout = 20.seconds
proc handleMessage*(
    wf: WakuFilter, pubsubTopic: PubsubTopic, message: WakuMessage
) {.async.} =
  let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()

  trace "handling message", pubsubTopic = pubsubTopic, msg_hash = msgHash

  let handleMessageStartTime = Moment.now()

  block:
    ## Find subscribers and push message to them
    let subscribedPeers =
      wf.subscriptions.findSubscribedPeers(pubsubTopic, message.contentTopic)
    if subscribedPeers.len == 0:
      trace "no subscribed peers found",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        msg_hash = msgHash
      return

    let messagePush = MessagePush(pubsubTopic: pubsubTopic, wakuMessage: message)

    if not await wf.pushToPeers(subscribedPeers, messagePush).withTimeout(
      MessagePushTimeout
    ):
      error "timed out pushing message to peers",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        msg_hash = msgHash,
        numPeers = subscribedPeers.len,
        target_peer_ids = subscribedPeers.mapIt(shortLog(it))
      waku_filter_errors.inc(labelValues = [pushTimeoutFailure])
    else:
      notice "pushed message succesfully to all subscribers",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        msg_hash = msgHash,
        numPeers = subscribedPeers.len,
        target_peer_ids = subscribedPeers.mapIt(shortLog(it))

  let
    handleMessageDuration = Moment.now() - handleMessageStartTime
    handleMessageDurationSec = handleMessageDuration.milliseconds.float / 1000
      # Duration in seconds with millisecond precision floating point
  waku_filter_handle_message_duration_seconds.observe(handleMessageDurationSec)

proc initProtocolHandler(wf: WakuFilter) =
  proc handler(conn: Connection, proto: string) {.async.} =
    trace "filter subscribe request handler triggered", peer_id = shortLog(conn.peerId)

    let buf = await conn.readLp(int(DefaultMaxSubscribeSize))

    let decodeRes = FilterSubscribeRequest.decode(buf)
    if decodeRes.isErr():
      error "Failed to decode filter subscribe request",
        peer_id = conn.peerId, err = decodeRes.error
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    let request = decodeRes.value #TODO: toAPI() split here

    let response = wf.handleSubscribeRequest(conn.peerId, request)

    debug "sending filter subscribe response",
      peer_id = shortLog(conn.peerId), response = response

    await conn.writeLp(response.encode().buffer) #TODO: toRPC() separation here
    return

  wf.handler = handler
  wf.codec = WakuFilterSubscribeCodec

proc new*(
    T: type WakuFilter,
    peerManager: PeerManager,
    subscriptionTimeout: Duration = DefaultSubscriptionTimeToLiveSec,
    maxFilterPeers: uint32 = MaxFilterPeers,
    maxFilterCriteriaPerPeer: uint32 = MaxFilterCriteriaPerPeer,
    messageCacheTTL: Duration = MessageCacheTTL,
): T =
  let wf = WakuFilter(
    subscriptions: FilterSubscriptions.init(
      subscriptionTimeout, maxFilterPeers, maxFilterCriteriaPerPeer
    ),
    peerManager: peerManager,
    messageCache: init(TimedCache[string], messageCacheTTL),
  )

  wf.initProtocolHandler()
  return wf

const MaintainSubscriptionsInterval* = 1.minutes

proc startMaintainingSubscriptions(wf: WakuFilter, interval: Duration) =
  trace "starting to maintain subscriptions"
  var maintainSubs: CallbackFunc
  maintainSubs = CallbackFunc(
    proc(udata: pointer) {.gcsafe.} =
      maintainSubscriptions(wf)
      wf.maintenanceTask = setTimer(Moment.fromNow(interval), maintainSubs)
  )

  wf.maintenanceTask = setTimer(Moment.fromNow(interval), maintainSubs)

method start*(wf: WakuFilter) {.async, base.} =
  debug "starting filter protocol"
  wf.startMaintainingSubscriptions(MaintainSubscriptionsInterval)

  await procCall LPProtocol(wf).start()

method stop*(wf: WakuFilter) {.async, base.} =
  debug "stopping filter protocol"
  if not wf.maintenanceTask.isNil():
    wf.maintenanceTask.clearTimer()

  await procCall LPProtocol(wf).stop()
