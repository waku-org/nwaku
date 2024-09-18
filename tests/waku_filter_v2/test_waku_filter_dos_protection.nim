{.used.}

import
  std/[options, tables, sequtils, strutils, json],
  testutils/unittests,
  stew/[results, byteutils],
  chronos,
  chronicles,
  os,
  libp2p/peerstore

import
  waku/[
    node/peer_manager,
    waku_core,
    common/rate_limit/setting,
    common/rate_limit/token_bucket,
  ],
  waku/waku_filter_v2/[common, client, subscriptions, protocol, rpc_codec],
  ../testlib/[wakucore, testasync, testutils, futures, sequtils],
  ./waku_filter_utils,
  ../resources/payloads

type AFilterClient = ref object of RootObj
  clientSwitch*: Switch
  wakuFilterClient*: WakuFilterClient
  clientPeerId*: PeerId
  messagePushHandler*: FilterPushHandler
  msgSeq*: seq[(PubsubTopic, WakuMessage)]
  pushHandlerFuture*: Future[(PubsubTopic, WakuMessage)]

proc init(T: type[AFilterClient]): T =
  var r = T(
    clientSwitch: newStandardSwitch(),
    msgSeq: @[],
    pushHandlerFuture: newPushHandlerFuture(),
  )
  r.wakuFilterClient = waitFor newTestWakuFilterClient(r.clientSwitch)
  r.messagePushHandler = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[void] {.async, closure, gcsafe.} =
    r.msgSeq.add((pubsubTopic, message))
    r.pushHandlerFuture.complete((pubsubTopic, message))

  r.clientPeerId = r.clientSwitch.peerInfo.toRemotePeerInfo().peerId
  r.wakuFilterClient.registerPushHandler(r.messagePushHandler)
  return r

proc subscribe(
    client: AFilterClient,
    serverRemotePeerInfo: RemotePeerInfo,
    pubsubTopic: PubsubTopic,
    contentTopicSeq: seq[ContentTopic],
): Option[FilterSubscribeErrorKind] =
  let subscribeResponse = waitFor client.wakuFilterClient.subscribe(
    serverRemotePeerInfo, pubsubTopic, contentTopicSeq
  )
  if subscribeResponse.isOk():
    return none[FilterSubscribeErrorKind]()

  return some(subscribeResponse.error().kind)

proc unsubscribe(
    client: AFilterClient,
    serverRemotePeerInfo: RemotePeerInfo,
    pubsubTopic: PubsubTopic,
    contentTopicSeq: seq[ContentTopic],
): Option[FilterSubscribeErrorKind] =
  let unsubscribeResponse = waitFor client.wakuFilterClient.unsubscribe(
    serverRemotePeerInfo, pubsubTopic, contentTopicSeq
  )
  if unsubscribeResponse.isOk():
    return none[FilterSubscribeErrorKind]()

  return some(unsubscribeResponse.error().kind)

proc ping(
    client: AFilterClient, serverRemotePeerInfo: RemotePeerInfo
): Option[FilterSubscribeErrorKind] =
  let pingResponse = waitFor client.wakuFilterClient.ping(serverRemotePeerInfo)
  if pingResponse.isOk():
    return none[FilterSubscribeErrorKind]()

  return some(pingResponse.error().kind)

suite "Waku Filter - DOS protection":
  var serverSwitch {.threadvar.}: Switch
  var client1 {.threadvar.}: AFilterClient
  var client2 {.threadvar.}: AFilterClient
  var wakuFilter {.threadvar.}: WakuFilter
  var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
  var pubsubTopic {.threadvar.}: PubsubTopic
  var contentTopic {.threadvar.}: ContentTopic
  var contentTopicSeq {.threadvar.}: seq[ContentTopic]

  asyncSetup:
    client1 = AFilterClient.init()
    client2 = AFilterClient.init()

    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    contentTopicSeq = @[contentTopic]
    serverSwitch = newStandardSwitch()
    wakuFilter = await newTestWakuFilter(
      serverSwitch, rateLimitSetting = some((3, 1000.milliseconds))
    )

    await allFutures(
      serverSwitch.start(), client1.clientSwitch.start(), client2.clientSwitch.start()
    )
    serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    client1.clientPeerId = client1.clientSwitch.peerInfo.toRemotePeerInfo().peerId
    client2.clientPeerId = client2.clientSwitch.peerInfo.toRemotePeerInfo().peerId

  asyncTeardown:
    await allFutures(
      wakuFilter.stop(),
      client1.wakuFilterClient.stop(),
      client2.wakuFilterClient.stop(),
      serverSwitch.stop(),
      client1.clientSwitch.stop(),
      client2.clientSwitch.stop(),
    )

  asyncTest "Limit number of subscriptions requests":
    # Given
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)

    await sleepAsync(20.milliseconds)
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    await sleepAsync(20.milliseconds)
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    await sleepAsync(20.milliseconds)
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      some(FilterSubscribeErrorKind.TOO_MANY_REQUESTS)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      some(FilterSubscribeErrorKind.TOO_MANY_REQUESTS)

    # ensure period of time has passed and clients can again use the service
    await sleepAsync(1000.milliseconds)
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)

  asyncTest "Ensure normal usage allowed":
    # Given
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId)

    await sleepAsync(500.milliseconds)
    check client1.ping(serverRemotePeerInfo) == none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId)

    await sleepAsync(500.milliseconds)
    check client1.ping(serverRemotePeerInfo) == none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId)

    await sleepAsync(50.milliseconds)
    check client1.unsubscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId) == false

    await sleepAsync(50.milliseconds)
    check client1.ping(serverRemotePeerInfo) == some(FilterSubscribeErrorKind.NOT_FOUND)
    check client1.ping(serverRemotePeerInfo) == some(FilterSubscribeErrorKind.NOT_FOUND)
    await sleepAsync(50.milliseconds)
    check client1.ping(serverRemotePeerInfo) ==
      some(FilterSubscribeErrorKind.TOO_MANY_REQUESTS)

    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client2.clientPeerId) == true
