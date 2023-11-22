{.used.}

import
  std/[options, times],
  stew/shims/net as stewNet,
  chronicles,
  testutils/unittests,
  eth/keys,
  presto, presto/client as presto_client,
  libp2p/crypto/crypto
import
  ../../../waku/waku_core/message,
  ../../../waku/waku_core/message/digest,
  ../../../waku/waku_core/topics,
  ../../../waku/waku_core/time,
  ../../../waku/waku_node,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_api/rest/server,
  ../../../waku/waku_api/rest/client,
  ../../../waku/waku_api/rest/responses,
  ../../../waku/waku_api/rest/store/handlers as store_api,
  ../../../waku/waku_api/rest/store/client as store_api_client,
  ../../../waku/waku_api/rest/store/types,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/queue_driver,
  ../../../waku/waku_store as waku_store,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

logScope:
  topics = "waku node rest store_api test"

proc put(store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage): Future[Result[void, string]] =
  let
    digest = waku_archive.computeDigest(message)
    msgHash = computeMessageHash(pubsubTopic, message)
    receivedTime = if message.timestamp > 0: message.timestamp
                  else: getNanosecondTime(getTime().toUnixFloat())

  store.put(pubsubTopic, message, digest, msgHash, receivedTime)

# Creates a new WakuNode
proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

################################################################################
# Beginning of the tests
################################################################################
procSuite "Waku v2 Rest API - Store":

  asyncTest "MessageDigest <-> string conversions":
    # Validate MessageDigest conversion from a WakuMessage obj
    let wakuMsg = WakuMessage(
      contentTopic: "Test content topic",
      payload: @[byte('H'), byte('i'), byte('!')]
    )

    let messageDigest = waku_store.computeDigest(wakuMsg)
    let restMsgDigest = some(messageDigest.toRestStringMessageDigest())
    let parsedMsgDigest = restMsgDigest.parseMsgDigest().value

    check:
      messageDigest == parsedMsgDigest.get()

    # Random validation. Obtained the raw values manually
    let expected = some("ZjNhM2Q2NDkwMTE0MjMzNDg0MzJlMDdiZGI3NzIwYTc%3D")
    let msgDigest = expected.parseMsgDigest().value
    check:
      expected.get() == msgDigest.get().toRestStringMessageDigest()

  asyncTest "Filter by start and end time":
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58011)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("ct1"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 1, byte 2], ts=2),
      fakeWakuMessage(@[byte 1], ts=3),
      fakeWakuMessage(@[byte 1], ts=4),
      fakeWakuMessage(@[byte 1], ts=5),
      fakeWakuMessage(@[byte 1], ts=6),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("c2"), ts=9)
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] &
                  "/p2p/" & $remotePeerInfo.peerId

    # Apply filter by start and end timestamps
    var response =
          await client.getStoreMessagesV1(
                        encodeUrl(fullAddr),
                        encodeUrl(DefaultPubsubTopic),
                        "", # empty content topics. Don't filter by this field
                        "3", # start time
                        "6", # end time
                        "", # sender time
                        "", # store time
                        "", # base64-encoded digest
                        "", # empty implies default page size
                        "true" # ascending
          )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 4

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Store node history response - forward pagination":
    # Test adapted from the analogous present at waku_store/test_wakunode_store.nim
    let node = testWakuNode()
    await node.start()

    let restPort = Port(58012)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let timeOrigin = wakucore.now()
    let msgList = @[
      fakeWakuMessage(@[byte 00], ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 01], ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 02], ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 03], ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 04], ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 05], ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 06], ts=ts(60, timeOrigin)),
      fakeWakuMessage(@[byte 07], ts=ts(70, timeOrigin)),
      fakeWakuMessage(@[byte 08], ts=ts(80, timeOrigin)),
      fakeWakuMessage(@[byte 09], ts=ts(90, timeOrigin))
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] &
                  "/p2p/" & $remotePeerInfo.peerId

    var pages = newSeq[seq[WakuMessage]](2)

    # Fields that compose a HistoryCursor object
    var reqPubsubTopic = DefaultPubsubTopic
    var reqSenderTime = Timestamp(0)
    var reqStoreTime = Timestamp(0)
    var reqDigest = waku_store.MessageDigest()

    for i in 0..<2:
      let response =
            await client.getStoreMessagesV1(
                          encodeUrl(fullAddr),
                          encodeUrl(reqPubsubTopic),
                          "", # content topics. Empty ignores the field.
                          "", # start time. Empty ignores the field.
                          "", # end time. Empty ignores the field.
                          encodeUrl($reqSenderTime), # sender time
                          encodeUrl($reqStoreTime), # store time
                          reqDigest.toRestStringMessageDigest(), # base64-encoded digest. Empty ignores the field.
                          "7", # page size. Empty implies default page size.
                          "true" # ascending
            )

      var wakuMessages = newSeq[WakuMessage](0)
      for j in 0..<response.data.messages.len:
        wakuMessages.add(response.data.messages[j].toWakuMessage())

      pages[i] = wakuMessages

      # populate the cursor for next page
      if response.data.cursor.isSome():
        reqPubsubTopic = response.data.cursor.get().pubsubTopic
        reqDigest = response.data.cursor.get().digest
        reqSenderTime = response.data.cursor.get().senderTime
        reqStoreTime = response.data.cursor.get().storeTime

      check:
        response.status == 200
        $response.contentType == $MIMETYPE_JSON

    check:
      pages[0] == msgList[0..6]
      pages[1] == msgList[7..9]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "query a node and retrieve historical messages filtered by pubsub topic":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58013)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("2"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("2"), ts=9)
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] &
                  "/p2p/" & $remotePeerInfo.peerId

    # Filtering by a known pubsub topic
    var response =
          await client.getStoreMessagesV1(
                        encodeUrl($fullAddr),
                        encodeUrl(DefaultPubsubTopic))

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    response = await client.getStoreMessagesV1(encodeUrl($fullAddr))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    response =
          await client.getStoreMessagesV1(
                        encodeUrl($fullAddr),
                        encodeUrl("random pubsub topic"))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "retrieve historical messages from a provided store node address":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58014)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("ct1"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("ct2"), ts=9)
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] &
                  "/p2p/" & $remotePeerInfo.peerId

    # Filtering by a known pubsub topic.
    # We also pass the store-node address in the request.
    var response =
          await client.getStoreMessagesV1(
                        encodeUrl(fullAddr),
                        encodeUrl(DefaultPubsubTopic))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    # We also pass the store-node address in the request.
    response =
          await client.getStoreMessagesV1(
                        encodeUrl(fullAddr),
                        encodeUrl(""))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    # We also pass the store-node address in the request.
    response =
          await client.getStoreMessagesV1(
                        encodeUrl(fullAddr),
                        encodeUrl("random pubsub topic"))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

    # Receiving 400 response if setting wrong store-node address
    response =
          await client.getStoreMessagesV1(
                        encodeUrl("incorrect multi address format"),
                        encodeUrl("random pubsub topic"))
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.messages.len == 0
      response.data.error_message.get ==
        "Failed parsing remote peer info [MultiAddress.init [multiaddress: Invalid MultiAddress, must start with `/`]]"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "filter historical messages by content topic":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58015)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("ct1"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("ct2"), ts=9)
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] &
                  "/p2p/" & $remotePeerInfo.peerId

    # Filtering by content topic
    let response =
          await client.getStoreMessagesV1(
                        encodeUrl(fullAddr),
                        encodeUrl(DefaultPubsubTopic),
                        encodeUrl("ct1,ct2"))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 2

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "precondition failed":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58016)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    
    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("ct1"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("ct2"), ts=9)
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] &
                  "/p2p/" & $remotePeerInfo.peerId

    # Sending no peer-store node address
    var response =
          await client.getStoreMessagesV1(
                        encodeUrl(""),
                        encodeUrl(DefaultPubsubTopic))
    check:
      response.status == 412
      $response.contentType == $MIMETYPE_TEXT
      response.data.messages.len == 0
      response.data.error_message.get == NoPeerNoDiscError.errobj.message

    # Now add the storenode from "config"
    node.peerManager.addServicePeer(remotePeerInfo,
                                    WakuStoreCodec)

    # Sending no peer-store node address
    response =
          await client.getStoreMessagesV1(
                        encodeUrl(""),
                        encodeUrl(DefaultPubsubTopic))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
