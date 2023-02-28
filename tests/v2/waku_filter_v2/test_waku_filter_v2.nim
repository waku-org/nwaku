{.used.}

import
  std/[options,sets,strutils,tables],
  testutils/unittests,
  chronos,
  chronicles
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/protocol/waku_filter_v2,
  ../../../waku/v2/protocol/waku_filter_v2/rpc,
  ../../../waku/v2/protocol/waku_message,
  ../testlib/common,
  ../testlib/waku2

proc newTestWakuFilter(switch: Switch): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

proc generateRequestId(rng: ref HmacDrbgContext): string =
  var bytes: array[10, byte]
  hmacDrbgGenerate(rng[], bytes)
  return toHex(bytes)

proc createRequest(filterSubscribeType: FilterSubscribeType, pubsubTopic = none(PubsubTopic), contentTopics = newSeq[ContentTopic]()): FilterSubscribeRequest =
  let requestId = generateRequestId(rng)

  return FilterSubscribeRequest(
    requestId: requestId,
    filterSubscribeType: filterSubscribeType,
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics
  )

proc getSubscribedContentTopics(wakuFilter: WakuFilter, peerId: PeerId): seq[ContentTopic] =
  var contentTopics: seq[ContentTopic]
  for filterCriterion in wakuFilter.subscriptions[peerId]:
    contentTopics.add(filterCriterion[1])

  return contentTopics

suite "Waku Filter - handling subscribe requests":

  asyncTest "simple subscribe and unsubscribe request":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic]
      )
      filterUnsubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest.pubsubTopic,
        contentTopics = filterSubscribeRequest.contentTopics
      )

    # When
    let response = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions[peerId].len == 1
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    let response2 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.len == 0 # peerId is removed from subscriptions
      response2.requestId == filterUnsubscribeRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

  asyncTest "simple subscribe and unsubscribe all for multiple content topics":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      nonDefaultContentTopic = ContentTopic("/waku/2/non-default-waku/proto")
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic, nonDefaultContentTopic]
      )
      filterUnsubscribeAllRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE_ALL
      )

    # When
    let response = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions[peerId].len == 2
      wakuFilter.getSubscribedContentTopics(peerId) == filterSubscribeRequest.contentTopics
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    let response2 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeAllRequest)

    # Then
    check:
      wakuFilter.subscriptions.len == 0 # peerId is removed from subscriptions
      response2.requestId == filterUnsubscribeAllRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

  asyncTest "subscribe and unsubscribe to multiple content topics":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      nonDefaultContentTopic = ContentTopic("/waku/2/non-default-waku/proto")
      filterSubscribeRequest1 = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic]
      )
      filterSubscribeRequest2 = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = filterSubscribeRequest1.pubsubTopic,
        contentTopics = @[nonDefaultContentTopic]
      )
      filterUnsubscribeRequest1 = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest1.pubsubTopic,
        contentTopics = filterSubscribeRequest1.contentTopics
      )
      filterUnsubscribeRequest2 = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest2.pubsubTopic,
        contentTopics = filterSubscribeRequest2.contentTopics
      )

    # When
    let response1 = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest1)

    # Then
    check:
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions[peerId].len == 1
      wakuFilter.getSubscribedContentTopics(peerId) == filterSubscribeRequest1.contentTopics
      response1.requestId == filterSubscribeRequest1.requestId
      response1.statusCode == 200
      response1.statusDesc.get() == "OK"

    # When
    let response2 = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest2)

    # Then
    check:
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions[peerId].len == 2
      wakuFilter.getSubscribedContentTopics(peerId) ==
        filterSubscribeRequest1.contentTopics &
        filterSubscribeRequest2.contentTopics
      response2.requestId == filterSubscribeRequest2.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

    # When
    let response3 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeRequest1)

    # Then
    check:
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions[peerId].len == 1
      wakuFilter.getSubscribedContentTopics(peerId) == filterSubscribeRequest2.contentTopics
      response3.requestId == filterUnsubscribeRequest1.requestId
      response3.statusCode == 200
      response3.statusDesc.get() == "OK"

    # When
    let response4 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeRequest2)

    # Then
    check:
      wakuFilter.subscriptions.len == 0 # peerId is removed from subscriptions
      response4.requestId == filterUnsubscribeRequest2.requestId
      response4.statusCode == 200
      response4.statusDesc.get() == "OK"

  asyncTest "ping subscriber":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      pingRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBER_PING
      )
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic]
      )

    # When
    let response1 = wakuFilter.handleSubscribeRequest(peerId, pingRequest)

    # Then
    check:
      response1.requestId == pingRequest.requestId
      response1.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response1.statusDesc.get().contains("peer has no subscriptions")

    # When
    let
      response2 = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest)
      response3 = wakuFilter.handleSubscribeRequest(peerId, pingRequest)

    # Then
    check:
      response2.requestId == filterSubscribeRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"
      response3.requestId == pingRequest.requestId
      response3.statusCode == 200
      response3.statusDesc.get() == "OK"

