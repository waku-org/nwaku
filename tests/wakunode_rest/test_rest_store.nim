{.used.}

import
  std/[options, times],
  stew/shims/net as stewNet,
  chronicles,
  testutils/unittests,
  eth/keys,
  presto,
  presto/client as presto_client,
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
  ../../../waku/common/base64,
  ../testlib/wakucore,
  ../testlib/wakunode

logScope:
  topics = "waku node rest store_api test"

proc put(
    store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[Result[void, string]] =
  let
    digest = computeDigest(message)
    msgHash = computeMessageHash(pubsubTopic, message)
    receivedTime =
      if message.timestamp > 0:
        message.timestamp
      else:
        getNanosecondTime(getTime().toUnixFloat())

  store.put(pubsubTopic, message, digest, msgHash, receivedTime)

# Creates a new WakuNode
proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

################################################################################
# Beginning of the tests
################################################################################
procSuite "Waku Rest API - Store v3":
  asyncTest "MessageHash <-> string conversions":
    # Validate MessageHash conversion from a WakuMessage obj
    let wakuMsg = WakuMessage(
      contentTopic: "Test content topic", payload: @[byte('H'), byte('i'), byte('!')]
    )

    let messageHash = computeMessageHash(DefaultPubsubTopic, wakuMsg)
    let restMsgHash = some(messageHash.toRestStringWakuMessageHash())

    let parsedMsgHashRes = parseHash(restMsgHash)
    assert parsedMsgHashRes.isOk(), $parsedMsgHashRes.error

    check:
      messageHash == parsedMsgHashRes.get().get()

    # Random validation. Obtained the raw values manually
    let expected = some("f6za9OzG1xSiEZagZc2b3litRbkd3zRl61rezDd3pgQ%3D")

    let msgHashRes = parseHash(expected)
    assert msgHashRes.isOk(), $msgHashRes.error

    check:
      expected.get() == msgHashRes.get().get().toRestStringWakuMessageHash()

  asyncTest "Filter by start and end time":
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58011)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

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
    let msgList =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 1, byte 2], ts = 2),
        fakeWakuMessage(@[byte 1], ts = 3),
        fakeWakuMessage(@[byte 1], ts = 4),
        fakeWakuMessage(@[byte 1], ts = 5),
        fakeWakuMessage(@[byte 1], ts = 6),
        fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("c2"), ts = 9),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Apply filter by start and end timestamps
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      encodeUrl(DefaultPubsubTopic),
      "", # empty content topics. Don't filter by this field
      "3", # start time
      "6", # end time
      "", # hashes
      "", # base64-encoded hash
      "true", # ascending
      "", # empty implies default page size
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
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

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
    let msgList =
      @[
        fakeWakuMessage(@[byte 00], ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 01], ts = ts(10, timeOrigin)),
        fakeWakuMessage(@[byte 02], ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 03], ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 04], ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 05], ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 06], ts = ts(60, timeOrigin)),
        fakeWakuMessage(@[byte 07], ts = ts(70, timeOrigin)),
        fakeWakuMessage(@[byte 08], ts = ts(80, timeOrigin)),
        fakeWakuMessage(@[byte 09], ts = ts(90, timeOrigin)),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    var pages = newSeq[seq[WakuMessage]](2)

    var reqHash = none(WakuMessageHash)

    for i in 0 ..< 2:
      let response = await client.getStoreMessagesV3(
        encodeUrl(fullAddr),
        "true", # include data
        encodeUrl(DefaultPubsubTopic),
        "", # content topics. Empty ignores the field.
        "", # start time. Empty ignores the field.
        "", # end time. Empty ignores the field.
        "", # hashes
        if reqHash.isSome():
          reqHash.get().toRestStringWakuMessageHash()
        else:
          ""
        , # base64-encoded digest. Empty ignores the field.
        "true", # ascending
        "7", # page size. Empty implies default page size.
      )

      var wakuMessages = newSeq[WakuMessage](0)
      for j in 0 ..< response.data.messages.len:
        wakuMessages.add(response.data.messages[j].message)

      pages[i] = wakuMessages

      # populate the cursor for next page
      if response.data.paginationCursor.isSome():
        reqHash = some(response.data.paginationCursor.get())

      check:
        response.status == 200
        $response.contentType == $MIMETYPE_JSON

    check:
      pages[0] == msgList[0 .. 6]
      pages[1] == msgList[7 .. 9]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "query a node and retrieve historical messages filtered by pubsub topic":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58013)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

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
    let msgList =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("2"), ts = 0),
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("2"), ts = 9),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Filtering by a known pubsub topic
    var response = await client.getStoreMessagesV3(
      encodeUrl($fullAddr), "true", encodeUrl(DefaultPubsubTopic)
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    response = await client.getStoreMessagesV3(encodeUrl($fullAddr), "true")
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    response = await client.getStoreMessagesV3(
      encodeUrl($fullAddr), "true", encodeUrl("random pubsub topic")
    )
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
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

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
    let msgList =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Filtering by a known pubsub topic.
    # We also pass the store-node address in the request.
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr), "true", encodeUrl(DefaultPubsubTopic)
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    # We also pass the store-node address in the request.
    response =
      await client.getStoreMessagesV3(encodeUrl(fullAddr), "true", encodeUrl(""))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    # We also pass the store-node address in the request.
    response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr), "true", encodeUrl("random pubsub topic")
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

    # Receiving 400 response if setting wrong store-node address
    response = await client.getStoreMessagesV3(
      encodeUrl("incorrect multi address format"),
      "true",
      encodeUrl("random pubsub topic"),
    )
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.messages.len == 0
      response.data.statusDesc ==
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
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

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
    let msgList =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Filtering by content topic
    let response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr), "true", encodeUrl(DefaultPubsubTopic), encodeUrl("ct1,ct2")
    )
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
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()

    # Sending no peer-store node address
    var response = await client.getStoreMessagesV3(
      encodeUrl(""), "true", encodeUrl(DefaultPubsubTopic)
    )
    check:
      response.status == 412
      $response.contentType == $MIMETYPE_TEXT
      response.data.messages.len == 0
      response.data.statusDesc == NoPeerNoDiscError.errobj.message

    # Now add the storenode from "config"
    node.peerManager.addServicePeer(remotePeerInfo, WakuStoreCodec)

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()

    # Now prime it with some history before tests
    let msgList =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    # Sending no peer-store node address
    response = await client.getStoreMessagesV3(
      encodeUrl(""), "true", encodeUrl(DefaultPubsubTopic)
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "retrieve historical messages from a self-store-node":
    ## This test aims to validate the correct message retrieval for a store-node which exposes
    ## a REST server.

    # Given
    let node = testWakuNode()
    await node.start()

    let restPort = Port(58017)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()

    # Now prime it with some history before tests
    let msgList =
      @[
        fakeWakuMessage(
          @[byte 0], contentTopic = ContentTopic("ct1"), ts = 0, meta = (@[byte 8])
        ),
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # Filtering by a known pubsub topic.
    var response = await client.getStoreMessagesV3(
      includeData = "true", pubsubTopic = encodeUrl(DefaultPubsubTopic)
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    response =
      await client.getStoreMessagesV3(includeData = "true", pubsubTopic = encodeUrl(""))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    response = await client.getStoreMessagesV3(
      includeData = "true", pubsubTopic = encodeUrl("random pubsub topic")
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

  asyncTest "correct message fields are returned":
    # Given
    let node = testWakuNode()
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()

    # Now prime it with some history before tests
    let msg = fakeWakuMessage(
      @[byte 0], contentTopic = ContentTopic("ct1"), ts = 0, meta = (@[byte 8])
    )
    require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # Filtering by a known pubsub topic.
    var response =
      await client.getStoreMessagesV3(pubsubTopic = encodeUrl(DefaultPubsubTopic))

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 1

    let storeMessage = response.data.messages[0].message

    check:
      storeMessage.payload == msg.payload
      storeMessage.contentTopic == msg.contentTopic
      storeMessage.version == msg.version
      storeMessage.timestamp == msg.timestamp
      storeMessage.ephemeral == msg.ephemeral
      storeMessage.meta == msg.meta

  asyncTest "Rate limit store node store query":
    # Test adapted from the analogous present at waku_store/test_wakunode_store.nim
    let node = testWakuNode()
    await node.start()

    let restPort = Port(58018)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore((2, 500.millis))
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let timeOrigin = wakucore.now()
    let msgList =
      @[
        fakeWakuMessage(@[byte 00], ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 01], ts = ts(10, timeOrigin)),
        fakeWakuMessage(@[byte 02], ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 03], ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 04], ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 05], ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 06], ts = ts(60, timeOrigin)),
        fakeWakuMessage(@[byte 07], ts = ts(70, timeOrigin)),
        fakeWakuMessage(@[byte 08], ts = ts(80, timeOrigin)),
        fakeWakuMessage(@[byte 09], ts = ts(90, timeOrigin)),
      ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    var pages = newSeq[seq[WakuMessage]](2)

    var reqPubsubTopic = DefaultPubsubTopic
    var reqHash = none(WakuMessageHash)

    for i in 0 ..< 2:
      let response = await client.getStoreMessagesV3(
        encodeUrl(fullAddr),
        "true", # include data
        encodeUrl(reqPubsubTopic),
        "", # content topics. Empty ignores the field.
        "", # start time. Empty ignores the field.
        "", # end time. Empty ignores the field.
        "", # hashes
        if reqHash.isSome():
          reqHash.get().toRestStringWakuMessageHash()
        else:
          ""
        , # base64-encoded digest. Empty ignores the field.
        "true", # ascending
        "3", # page size. Empty implies default page size.
      )

      var wakuMessages = newSeq[WakuMessage](0)
      for j in 0 ..< response.data.messages.len:
        wakuMessages.add(response.data.messages[j].message)

      pages[i] = wakuMessages

      # populate the cursor for next page
      if response.data.paginationCursor.isSome():
        reqHash = response.data.paginationCursor

      check:
        response.status == 200
        $response.contentType == $MIMETYPE_JSON

    check:
      pages[0] == msgList[0 .. 2]
      pages[1] == msgList[3 .. 5]

    # request last third will lead to rate limit rejection
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      encodeUrl(reqPubsubTopic),
      "", # content topics. Empty ignores the field.
      "", # start time. Empty ignores the field.
      "", # end time. Empty ignores the field.
      "", # hashes
      if reqHash.isSome():
        reqHash.get().toRestStringWakuMessageHash()
      else:
        ""
      , # base64-encoded digest. Empty ignores the field.
    )

    check:
      response.status == 429
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc == "Request rate limit reached"

    await sleepAsync(500.millis)

    # retry after respective amount of time shall succeed
    response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      encodeUrl(reqPubsubTopic),
      "", # content topics. Empty ignores the field.
      "", # start time. Empty ignores the field.
      "", # end time. Empty ignores the field.
      "", # hashes
      if reqHash.isSome():
        reqHash.get().toRestStringWakuMessageHash()
      else:
        ""
      , # base64-encoded digest. Empty ignores the field.
      "true", # ascending
      "5", # page size. Empty implies default page size.
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON

    var wakuMessages = newSeq[WakuMessage](0)
    for j in 0 ..< response.data.messages.len:
      wakuMessages.add(response.data.messages[j].message)

    check wakuMessages == msgList[6 .. 9]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
