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
  ./rpc

logScope:
  topics = "waku filter"

const
  MaxSubscriptions* = 1000 # TODO make configurable
  MaxCriteriaPerSubscription = 1000

type
  FilterCriterion* = (PubsubTopic, ContentTopic) # a single filter criterion is fully defined by a pubsub topic and content topic
  FilterCriteria* = HashSet[FilterCriterion] # a sequence of filter criteria

  WakuFilter* = ref object of LPProtocol
    subscriptions*: Table[PeerID, FilterCriteria] # a mapping of peer ids to a sequence of filter criteria
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
    if wf.subscriptions.len() >= MaxSubscriptions:
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

proc handleMessage*(wf: WakuFilter, message: WakuMessage) =
  raiseAssert "Unimplemented"

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
