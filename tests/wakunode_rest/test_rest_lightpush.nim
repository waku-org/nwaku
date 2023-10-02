{.used.}

import
  std/sequtils,
  stew/byteutils,
  stew/shims/net,
  testutils/unittests,
  presto, presto/client as presto_client,
  libp2p/crypto/crypto

import
  ../../waku/waku_api/message_cache,
  ../../waku/common/base64,
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/node/peer_manager,
  ../../waku/waku_lightpush,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/client,
  ../../waku/waku_api/rest/responses,
  ../../waku/waku_api/rest/lightpush/types,
  ../../waku/waku_api/rest/lightpush/handlers as lightpush_api,
  ../../waku/waku_api/rest/lightpush/client as lightpush_api_client,
  ../../waku/waku_relay,
  ../testlib/wakucore,
  ../testlib/wakunode


proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))


type RestLightPushTest = object
  serviceNode: WakuNode
  pushNode: WakuNode
  consumerNode: WakuNode
  restServer: RestServerRef
  client: RestClientRef


proc init(T: type RestLightPushTest): Future[T] {.async.} =
  var testSetup = RestLightPushTest()
  testSetup.serviceNode = testWakuNode()
  testSetup.pushNode = testWakuNode()
  testSetup.consumerNode = testWakuNode()

  await allFutures(testSetup.serviceNode.start(),
                   testSetup.pushNode.start(),
                   testSetup.consumerNode.start())

  await testSetup.consumerNode.mountRelay()
  await testSetup.serviceNode.mountRelay()
  await testSetup.serviceNode.mountLightPush()
  testSetup.pushNode.mountLightPushClient()


  testSetup.serviceNode.peerManager.addServicePeer(
            testSetup.consumerNode.peerInfo.toRemotePeerInfo(),
            WakuRelayCodec)

  await testSetup.serviceNode.connectToNodes(@[testSetup.consumerNode.peerInfo.toRemotePeerInfo()])

  testSetup.pushNode.peerManager.addServicePeer(
            testSetup.serviceNode.peerInfo.toRemotePeerInfo(),
            WakuLightPushCodec)

  let restPort = Port(58011)
  let restAddress = ValidIpAddress.init("127.0.0.1")
  testSetup.restServer = RestServerRef.init(restAddress, restPort).tryGet()

  installLightPushRequestHandler(testSetup.restServer.router, testSetup.pushNode)

  testSetup.restServer.start()

  testSetup.client = newRestHttpClient(initTAddress(restAddress, restPort))

  return testSetup


proc shutdown(self: RestLightPushTest) {.async.} =
  await self.restServer.stop()
  await self.restServer.closeWait()
  await allFutures(self.serviceNode.stop(), self.pushNode.stop())


suite "Waku v2 Rest API - lightpush":
  asyncTest "Push message request":
    # Given
    let restLightPushTest = await RestLightPushTest.init()

    restLightPushTest.consumerNode.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    restLightPushTest.serviceNode.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    require:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let message : RelayWakuMessage = fakeWakuMessage(contentTopic = DefaultContentTopic,
                                                     payload = toBytes("TEST-1")).toRelayWakuMessage()

    let requestBody = PushRequest(pubsubTopic: some(DefaultPubsubTopic),
                                  message: message)
    let response = await restLightPushTest.client.sendPushRequest(requestBody)

    echo "response", $response

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT

    await restLightPushTest.shutdown()

  asyncTest "Push message bad-request":
    # Given
    let restLightPushTest = await RestLightPushTest.init()

    restLightPushTest.serviceNode.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    require:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let badMessage1 : RelayWakuMessage = fakeWakuMessage(contentTopic = DefaultContentTopic,
                                                         payload = toBytes("")).toRelayWakuMessage()
    let badRequestBody1 = PushRequest(pubsubTopic: some(DefaultPubsubTopic),
                                      message: badMessage1)

    let badMessage2 : RelayWakuMessage = fakeWakuMessage(contentTopic = "",
                                                         payload = toBytes("Sthg")).toRelayWakuMessage()
    let badRequestBody2 = PushRequest(pubsubTopic: some(DefaultPubsubTopic),
                                      message: badMessage2)

    let badRequestBody3 = PushRequest(pubsubTopic: none(PubsubTopic),
                                      message: badMessage2)

    var response: RestResponse[string]

    response = await restLightPushTest.client.sendPushRequest(badRequestBody1)

    echo "response", $response

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith("Invalid content body")


    # when
    response = await restLightPushTest.client.sendPushRequest(badRequestBody2)

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith("Invalid content body")

    # when
    response = await restLightPushTest.client.sendPushRequest(badRequestBody3)

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith("Invalid content body")

    await restLightPushTest.shutdown()

  ## TODO: Re-work this test when lightpush protocol change is done: https://github.com/waku-org/pm/issues/93
  ## This test is similar when no available peer exists for publish. Currently it is returning success,
  ## that makes this test not useful.
  # asyncTest "Push message request service not available":
  #   # Given
  #   let restLightPushTest = await RestLightPushTest.init()

  #   # When
  #   let message : RelayWakuMessage = fakeWakuMessage(contentTopic = DefaultContentTopic,
  #                                                    payload = toBytes("TEST-1")).toRelayWakuMessage()

  #   let requestBody = PushRequest(pubsubTopic: some("NoExistTopic"),
  #                                 message: message)
  #   let response = await restLightPushTest.client.sendPushRequest(requestBody)

  #   echo "response", $response

  #   # Then
  #   check:
  #     response.status == 503
  #     $response.contentType == $MIMETYPE_TEXT
  #     response.data == "Failed to request a message push: Can not publish to any peers"

  #   await restLightPushTest.shutdown()
