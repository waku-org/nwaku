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
  ../../waku/waku_filter,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/client,
  ../../waku/waku_api/rest/responses,
  ../../waku/waku_api/rest/filter/types,
  ../../waku/waku_api/rest/filter/legacy_handlers as filter_api,
  ../../waku/waku_api/rest/filter/legacy_client as filter_api_client,
  ../../waku/waku_relay,
  ../testlib/wakucore,
  ../testlib/wakunode


proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))


type RestFilterTest = object
  filterNode: WakuNode
  clientNode: WakuNode
  restServer: RestServerRef
  messageCache: MessageCache
  client: RestClientRef


proc setupRestFilter(): Future[RestFilterTest] {.async.} =
  result.filterNode = testWakuNode()
  result.clientNode = testWakuNode()

  await allFutures(result.filterNode.start(), result.clientNode.start())

  await result.filterNode.mountFilter()
  await result.clientNode.mountFilterClient()

  result.clientNode.peerManager.addServicePeer(result.filterNode.peerInfo.toRemotePeerInfo()
                                               ,WakuLegacyFilterCodec)

  let restPort = Port(58011)
  let restAddress = parseIpAddress("0.0.0.0")
  result.restServer = RestServerRef.init(restAddress, restPort).tryGet()

  result.messageCache = MessageCache.init()
  installLegacyFilterRestApiHandlers(result.restServer.router
                                     ,result.clientNode
                                     ,result.messageCache)

  result.restServer.start()

  result.client = newRestHttpClient(initTAddress(restAddress, restPort))

  return result


proc shutdown(self: RestFilterTest) {.async.} =
  await self.restServer.stop()
  await self.restServer.closeWait()
  await allFutures(self.filterNode.stop(), self.clientNode.stop())


suite "Waku v2 Rest API - Filter":
  asyncTest "Subscribe a node to an array of topics - POST /filter/v1/subscriptions":
    # Given
    let  restFilterTest: RestFilterTest = await setupRestFilter()

    # When
    let contentFilters = @[DefaultContentTopic
                          ,ContentTopic("2")
                          ,ContentTopic("3")
                          ,ContentTopic("4")
                          ]

    let requestBody = FilterLegacySubscribeRequest(contentFilters: contentFilters,
                                                 pubsubTopic: some(DefaultPubsubTopic))
    let response = await restFilterTest.client.filterPostSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      restFilterTest.messageCache.isContentSubscribed(DefaultContentTopic)
      restFilterTest.messageCache.isContentSubscribed("2")
      restFilterTest.messageCache.isContentSubscribed("3")
      restFilterTest.messageCache.isContentSubscribed("4")

    # When - error case
    let badRequestBody = FilterLegacySubscribeRequest(contentFilters: @[]
                                                      ,pubsubTopic: none(string))
    let badResponse = await restFilterTest.client.filterPostSubscriptionsV1(badRequestBody)

    check:
      badResponse.status == 400
      $badResponse.contentType == $MIMETYPE_TEXT
      badResponse.data == "Invalid content body, could not decode. Unable to deserialize data"


    await restFilterTest.shutdown()


  asyncTest "Unsubscribe a node from an array of topics - DELETE /filter/v1/subscriptions":
    # Given
    let
      restFilterTest: RestFilterTest = await setupRestFilter()

    # When
    restFilterTest.messageCache.contentSubscribe("1")
    restFilterTest.messageCache.contentSubscribe("2")
    restFilterTest.messageCache.contentSubscribe("3")
    restFilterTest.messageCache.contentSubscribe("4")

    let contentFilters = @[ContentTopic("1")
                      ,ContentTopic("2")
                      ,ContentTopic("3")
                      # ,ContentTopic("4") # Keep this subscription for check
                      ]

    # When
    let requestBody = FilterLegacySubscribeRequest(contentFilters: contentFilters,
                                                pubsubTopic: some(DefaultPubsubTopic))
    let response = await restFilterTest.client.filterDeleteSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not restFilterTest.messageCache.isContentSubscribed("1")
      not restFilterTest.messageCache.isContentSubscribed("2")
      not restFilterTest.messageCache.isContentSubscribed("3")
      restFilterTest.messageCache.isContentSubscribed("4")

    await restFilterTest.shutdown()

  asyncTest "Get the latest messages for topic - GET /filter/v1/messages/{contentTopic}":
    # Given

    let
      restFilterTest = await setupRestFilter()

    let pubSubTopic = "/waku/2/default-waku/proto"
    let contentTopic = ContentTopic( "content-topic-x" )

    var messages = @[
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1"))
    ]

    # Prevent duplicate messages
    for i in 0..<2:
      var msg = fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1"))

      while msg == messages[i]:
        msg = fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1"))
      
      messages.add(msg)

    restFilterTest.messageCache.contentSubscribe(contentTopic)
    for msg in messages:
      restFilterTest.messageCache.addMessage(pubSubTopic, msg)

    # When
    let response = await restFilterTest.client.filterGetMessagesV1(contentTopic)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do (msg: FilterWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
        msg.contentTopic.get().string == "content-topic-x" and
        msg.version.get() == 2 and
        msg.timestamp.get() != Timestamp(0)

    await restFilterTest.shutdown()
