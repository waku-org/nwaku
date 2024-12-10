{.used.}

import
  std/[options, sequtils, sets, strutils, tables],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/peerstore
import
  waku/[
    node/peer_manager,
    waku_filter_v2,
    waku_filter_v2/rpc,
    waku_filter_v2/subscriptions,
    waku_core,
  ],
  ../testlib/common,
  ../testlib/wakucore,
  ./waku_filter_utils

proc newTestWakuFilter(switch: Switch): WakuFilter =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

  return proto

proc generateRequestId(rng: ref HmacDrbgContext): string =
  var bytes: array[10, byte]
  hmacDrbgGenerate(rng[], bytes)
  return toHex(bytes)

proc createRequest*(
    filterSubscribeType: FilterSubscribeType,
    pubsubTopic = none(PubsubTopic),
    contentTopics = newSeq[ContentTopic](),
): FilterSubscribeRequest =
  let requestId = generateRequestId(rng)

  return FilterSubscribeRequest(
    requestId: requestId,
    filterSubscribeType: filterSubscribeType,
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics,
  )

proc getSubscribedContentTopics(
    wakuFilter: WakuFilter, peerId: PeerId
): seq[ContentTopic] =
  var contentTopics: seq[ContentTopic] = @[]
  let peersCreitera = wakuFilter.subscriptions.getPeerSubscriptions(peerId)

  for filterCriterion in peersCreitera:
    contentTopics.add(filterCriterion.contentTopic)

  return contentTopics

suite "Waku Filter - handling subscribe requests":
  asyncTest "unsubscribe errors":
    ## Tests most common error paths while unsubscribing

    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId = PeerId.random().get()

    ## Incomplete filter criteria

    # When
    let
      reqNoPubsubTopic = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = none(PubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      reqNoContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[],
      )
      response1 = await wakuFilter.handleSubscribeRequest(peerId, reqNoPubsubTopic)
      response2 = await wakuFilter.handleSubscribeRequest(peerId, reqNoContentTopics)

    # Then
    check:
      response1.requestId == reqNoPubsubTopic.requestId
      response2.requestId == reqNoContentTopics.requestId
      response1.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response2.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response1.statusDesc.get().contains(
        "pubsubTopic and contentTopics must be specified"
      )
      response2.statusDesc.get().contains(
        "pubsubTopic and contentTopics must be specified"
      )

    ## Max content topics per request exceeded

    # When
    let
      contentTopics = toSeq(1 .. MaxContentTopicsPerRequest + 1).mapIt(
          ContentTopic("/waku/2/content-$#/proto" % [$it])
        )
      reqTooManyContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = contentTopics,
      )
      response3 =
        await wakuFilter.handleSubscribeRequest(peerId, reqTooManyContentTopics)

    # Then
    check:
      response3.requestId == reqTooManyContentTopics.requestId
      response3.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response3.statusDesc.get().contains("exceeds maximum content topics")

    ## Subscription not found - unsubscribe

    # When
    let
      reqSubscriptionNotFound = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      response4 =
        await wakuFilter.handleSubscribeRequest(peerId, reqSubscriptionNotFound)

    # Then
    check:
      response4.requestId == reqSubscriptionNotFound.requestId
      response4.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response4.statusDesc.get().contains("peer has no subscriptions")

    ## Subscription not found - unsubscribe all

    # When
    let
      reqUnsubscribeAll =
        createRequest(filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE_ALL)
      response5 = await wakuFilter.handleSubscribeRequest(peerId, reqUnsubscribeAll)

    # Then
    check:
      response5.requestId == reqUnsubscribeAll.requestId
      response5.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response5.statusDesc.get().contains("peer has no subscriptions")

suite "Waku Filter - subscription maintenance":
  asyncTest "simple maintenance":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId1 = PeerId.random().get()
      peerId2 = PeerId.random().get()
      peerId3 = PeerId.random().get()
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )

    # When
    switch.peerStore[ProtoBook][peerId1] = @[WakuFilterPushCodec]
    switch.peerStore[ProtoBook][peerId2] = @[WakuFilterPushCodec]
    switch.peerStore[ProtoBook][peerId3] = @[WakuFilterPushCodec]
    require (await wakuFilter.handleSubscribeRequest(peerId1, filterSubscribeRequest)).statusCode ==
      200
    require (await wakuFilter.handleSubscribeRequest(peerId2, filterSubscribeRequest)).statusCode ==
      200
    require (await wakuFilter.handleSubscribeRequest(peerId3, filterSubscribeRequest)).statusCode ==
      200

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 3
      wakuFilter.subscriptions.isSubscribed(peerId1)
      wakuFilter.subscriptions.isSubscribed(peerId2)
      wakuFilter.subscriptions.isSubscribed(peerId3)

    # When
    # Maintenance loop should leave all peers in peer store intact
    await wakuFilter.maintainSubscriptions()

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 3
      wakuFilter.subscriptions.isSubscribed(peerId1)
      wakuFilter.subscriptions.isSubscribed(peerId2)
      wakuFilter.subscriptions.isSubscribed(peerId3)

    # When
    # Remove peerId1 and peerId3 from peer store
    switch.peerStore.del(peerId1)
    switch.peerStore.del(peerId3)
    await wakuFilter.maintainSubscriptions()

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.isSubscribed(peerId2)

    # When
    # Remove peerId2 from peer store
    switch.peerStore.del(peerId2)
    await wakuFilter.maintainSubscriptions()

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
