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

proc createRequest(
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
  asyncTest "simple subscribe and unsubscribe request":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      filterUnsubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest.pubsubTopic,
        contentTopics = filterSubscribeRequest.contentTopics,
      )

    # When
    let response = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[peerId].criteriaCount == 1
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    let response2 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
        # peerId is removed from subscriptions
      response2.requestId == filterUnsubscribeRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

  asyncTest "simple subscribe and unsubscribe all for multiple content topics":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      nonDefaultContentTopic = ContentTopic("/waku/2/non-default-waku/proto")
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic, nonDefaultContentTopic],
      )
      filterUnsubscribeAllRequest =
        createRequest(filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE_ALL)

    # When
    let response = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[peerId].criteriaCount == 2
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(peerId),
        filterSubscribeRequest.contentTopics,
      )
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    let response2 =
      wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeAllRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
        # peerId is removed from subscriptions
      response2.requestId == filterUnsubscribeAllRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

  asyncTest "subscribe and unsubscribe to multiple content topics":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      nonDefaultContentTopic = ContentTopic("/waku/2/non-default-waku/proto")
      filterSubscribeRequest1 = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      filterSubscribeRequest2 = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = filterSubscribeRequest1.pubsubTopic,
        contentTopics = @[nonDefaultContentTopic],
      )
      filterUnsubscribeRequest1 = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest1.pubsubTopic,
        contentTopics = filterSubscribeRequest1.contentTopics,
      )
      filterUnsubscribeRequest2 = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest2.pubsubTopic,
        contentTopics = filterSubscribeRequest2.contentTopics,
      )

    # When
    let response1 = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest1)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[peerId].criteriaCount == 1
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(peerId),
        filterSubscribeRequest1.contentTopics,
      )
      response1.requestId == filterSubscribeRequest1.requestId
      response1.statusCode == 200
      response1.statusDesc.get() == "OK"

    # When
    let response2 = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest2)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[peerId].criteriaCount == 2
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(peerId),
        filterSubscribeRequest1.contentTopics & filterSubscribeRequest2.contentTopics,
      )
      response2.requestId == filterSubscribeRequest2.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

    # When
    let response3 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeRequest1)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[peerId].criteriaCount == 1
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(peerId),
        filterSubscribeRequest2.contentTopics,
      )
      response3.requestId == filterUnsubscribeRequest1.requestId
      response3.statusCode == 200
      response3.statusDesc.get() == "OK"

    # When
    let response4 = wakuFilter.handleSubscribeRequest(peerId, filterUnsubscribeRequest2)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
        # peerId is removed from subscriptions
      response4.requestId == filterUnsubscribeRequest2.requestId
      response4.statusCode == 200
      response4.statusDesc.get() == "OK"

  asyncTest "subscribe errors":
    ## Tests most common error paths while subscribing

    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId = PeerId.random().get()

    ## Incomplete filter criteria

    # When
    let
      reqNoPubsubTopic = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = none(PubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      reqNoContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[],
      )
      response1 = wakuFilter.handleSubscribeRequest(peerId, reqNoPubsubTopic)
      response2 = wakuFilter.handleSubscribeRequest(peerId, reqNoContentTopics)

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
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = contentTopics,
      )
      response3 = wakuFilter.handleSubscribeRequest(peerId, reqTooManyContentTopics)

    # Then
    check:
      response3.requestId == reqTooManyContentTopics.requestId
      response3.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response3.statusDesc.get().contains("exceeds maximum content topics")

    ## Max filter criteria exceeded

    # When
    let filterCriteria = toSeq(1 .. MaxFilterCriteriaPerPeer).mapIt(
        (DefaultPubsubTopic, ContentTopic("/waku/2/content-$#/proto" % [$it]))
      )

    discard wakuFilter.subscriptions.addSubscription(peerId, filterCriteria.toHashSet())

    let
      reqTooManyFilterCriteria = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      response4 = wakuFilter.handleSubscribeRequest(peerId, reqTooManyFilterCriteria)

    # Then
    check:
      response4.requestId == reqTooManyFilterCriteria.requestId
      response4.statusCode == FilterSubscribeErrorKind.SERVICE_UNAVAILABLE.uint32
      response4.statusDesc.get().contains(
        "peer has reached maximum number of filter criteria"
      )

    ## Max subscriptions exceeded

    # When
    wakuFilter.subscriptions.removePeer(peerId)
    wakuFilter.subscriptions.cleanUp()

    for _ in 1 .. MaxFilterPeers:
      discard wakuFilter.subscriptions.addSubscription(
        PeerId.random().get(), @[(DefaultPubsubTopic, DefaultContentTopic)].toHashSet()
      )

    let
      reqTooManySubscriptions = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      response5 = wakuFilter.handleSubscribeRequest(peerId, reqTooManySubscriptions)

    # Then
    check:
      response5.requestId == reqTooManySubscriptions.requestId
      response5.statusCode == FilterSubscribeErrorKind.SERVICE_UNAVAILABLE.uint32
      response5.statusDesc.get().contains(
        "node has reached maximum number of subscriptions"
      )

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
      response1 = wakuFilter.handleSubscribeRequest(peerId, reqNoPubsubTopic)
      response2 = wakuFilter.handleSubscribeRequest(peerId, reqNoContentTopics)

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
      response3 = wakuFilter.handleSubscribeRequest(peerId, reqTooManyContentTopics)

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
      response4 = wakuFilter.handleSubscribeRequest(peerId, reqSubscriptionNotFound)

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
      response5 = wakuFilter.handleSubscribeRequest(peerId, reqUnsubscribeAll)

    # Then
    check:
      response5.requestId == reqUnsubscribeAll.requestId
      response5.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response5.statusDesc.get().contains("peer has no subscriptions")

  asyncTest "ping subscriber":
    # Given
    let
      switch = newStandardSwitch()
      wakuFilter = newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      pingRequest =
        createRequest(filterSubscribeType = FilterSubscribeType.SUBSCRIBER_PING)
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
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
    require wakuFilter.handleSubscribeRequest(peerId1, filterSubscribeRequest).statusCode ==
      200
    require wakuFilter.handleSubscribeRequest(peerId2, filterSubscribeRequest).statusCode ==
      200
    require wakuFilter.handleSubscribeRequest(peerId3, filterSubscribeRequest).statusCode ==
      200

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 3
      wakuFilter.subscriptions.isSubscribed(peerId1)
      wakuFilter.subscriptions.isSubscribed(peerId2)
      wakuFilter.subscriptions.isSubscribed(peerId3)

    # When
    # Maintenance loop should leave all peers in peer store intact
    wakuFilter.maintainSubscriptions()

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
    wakuFilter.maintainSubscriptions()

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.isSubscribed(peerId2)

    # When
    # Remove peerId2 from peer store
    switch.peerStore.del(peerId2)
    wakuFilter.maintainSubscriptions()

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
