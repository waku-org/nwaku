## Waku Filter protocol for subscribing and filtering messages

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets,tables],
  libp2p/peerid
import
  ../../node/peer_manager,
  ../waku_message,
  ./common,
  ./codec

const
  MaxSubscriptions* = 1000 # TODO make configurable
  MaxCriteriaPerSubscription = 1000

type
  FilterCriterion* = (PubsubTopic, ContentTopic) # a single filter criterion is fully defined by a pubsub topic and content topic
  FilterCriteria* = HashSet[FilterCriterion] # a sequence of filter criteria

  WakuFilter* = object
    subscriptions*: Table[PeerID, FilterCriteria] # a mapping of peer ids to a sequence of filter criteria
    peerManager: PeerManager

proc pingSubscriber(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  if peerId notin wf.subscriptions:
    return err(FilterSubscribeError(
      kind: FilterSubscribeErrorKind.NOT_FOUND,
      cause: "NOT_FOUND: peer has no subscriptions"
    ))

  ok()

proc subscribe(wf: WakuFilter, peerId: PeerID, pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic]): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.isEmpty():
    return err(FilterSubscribeError(
      kind: FilterSubscribeErrorKind.BAD_REQUEST,
      cause: "BAD_REQUEST: pubsubTopic and contentTopics must be specified"
    ))

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  if peerId in wf.subscriptions:
    let peerSubscription = wf.subscriptions[peerId]
    if peerSubscription.len() + filterCriteria.length >= MaxCriteriaPerSubscription:
      return err(FilterSubscribeError(
        kind: FilterSubscribeErrorKind.BAD_REQUEST,
        cause: "BAD_REQUEST: peer has reached maximum number of filter criteria"
      ))

    wf.subscriptions[peerId].incl(filterCriteria)
  else:
    if wf.subscriptions.len() >= MaxSubscriptions:
      return err(FilterSubscribeError(
        kind: FilterSubscribeErrorKind.BAD_REQUEST,
        cause: "BAD_REQUEST: node has reached maximum number of subscriptions"
      ))
    wf.subscriptions[peerId] = filterCriteria

  ok()

proc unsubscribe(wf: WakuFilter, peerId: PeerID, pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic]): FilterSubscribeResult =
  if pubsubTopic.isNone() or contentTopics.isEmpty():
    return err(FilterSubscribeError(
      kind: FilterSubscribeErrorKind.BAD_REQUEST,
      cause: "BAD_REQUEST: pubsubTopic and contentTopics must be specified"
    ))

  let filterCriteria = toHashSet(contentTopics.mapIt((pubsubTopic.get(), it)))

  if peerId notin wf.subscriptions:
    return err(FilterSubscribeError(
      kind: FilterSubscribeErrorKind.NOT_FOUND,
      cause: "NOT_FOUND: peer has no subscriptions"
    ))

  let peerSubscription = wf.subscriptions[peerId]
  # TODO: consider error response if filter criteria does not exist
  wf.subscriptions[peerId].excl(filterCriteria)

  ok()

proc unsubscribeAll(wf: WakuFilter, peerId: PeerID): FilterSubscribeResult =
  if peerId notin wf.subscriptions:
    return err(FilterSubscribeError(
      kind: FilterSubscribeErrorKind.NOT_FOUND,
      cause: "NOT_FOUND: peer has no subscriptions"
    ))

  wf.subscriptions.del(peerId)

  ok()


proc handleSubscribeRequest*(wf: WakuFilter, request: FilterSubscribeRequest): FilterSubscribeResponse =
  var subscribeResult: FilterSubscribeResult

  case request.filterSubscribeType
  of SubscribeType.SUBSCRIBER_PING:
    subscribeResult = wf.pingSubscriber(request.peerId)
  of SubscribeType.SUBSCRIBE:
    subscribeResult = wf.subscribe(request.peerId, request.pubsubTopic, request.contentTopics)
  of SubscribeType.UNSUBSCRIBE:
    subscribeResult = wf.unsubscribe(request.peerId, request.pubsubTopic, request.contentTopics)
  of SubscribeType.UNSUBSCRIBE_ALL:
    subscribeResult = wf.unsubscribeAll(request.peerId)

  if subscribeResult.isErr():
    return FilterSubscribeResponse(
      requestId: requestId,
      statusCode: subscribeResult.error.kind,
      statusMessage: some($subscribeResult.error)
    )
  else:
    return FilterSubscribeResponse(
      requestId: requestId,
      statusCode: 200,
      statusMessage: some("OK")
    )

proc handleMessage*(wf: WakuFilter, message: WakuMessage) =
  raiseAssert "Unimplemented"

proc initProtocolHandler(wf: WakuFilter) =

  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(MaxSubscribeSize)

    let decodeRes = FilterSubscribeRequest.decode(buf)
    if decodeRes.isErr:
      error "Failed to decode filter subscribe request", peerId = $conn.peerId
      waku_filter_errors.inc[labelValues = decodeRpcFailure]
      return

    let request = decodeRes.value #TODO: toAPI() split here

    info "received filter subscribe request", peerId=$conn.peerId, request = request
    waku_filter_requests.inc()

    let response = wf.handleSubscribeRequest(request)

    await conn.writeLp(response.encode()) #TODO: toRPC() separation here
    return

  ws.handler = handler
  ws.codec = WakuFilterSubscribeCodec

proc new*(T: type WakuFilter,
          peerManager: PeerManager): T =

  let ws = WakuFilter(
    peerManager: peerManager
  )
  ws.initProtocolHandler()
  ws
