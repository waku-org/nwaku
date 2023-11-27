{.used.}

import
  std/[options, times, json],
  stew/shims/net as stewNet,
  testutils/unittests,
  eth/keys,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_node,
  ../../../waku/waku_api/jsonrpc/store/handlers as store_api,
  ../../../waku/waku_api/jsonrpc/store/client as store_api_client,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/queue_driver,
  ../../../waku/waku_store,
  ../../../waku/waku_store/rpc,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode


proc put(store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage): Future[Result[void, string]] =
  let
    digest = waku_archive.computeDigest(message)
    msgHash = computeMessageHash(pubsubTopic, message)
    receivedTime = if message.timestamp > 0: message.timestamp
                  else: getNanosecondTime(getTime().toUnixFloat())

  store.put(pubsubTopic, message, digest, msgHash, receivedTime)

procSuite "Waku v2 JSON-RPC API - Store":

  asyncTest "query a node and retrieve historical messages":
    let
      privkey = generateSecp256k1Key()
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")
      port = Port(0)
      node = newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

    await node.start()

    # RPC server setup
    let
      rpcPort = Port(8549)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installStoreApiHandlers(node, server)
    server.start()

    # WakuStore setup
    let
      key = generateEcdsaKey()
      peer = PeerInfo.new(key)

    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    node.peerManager.addServicePeer(listenSwitch.peerInfo.toRemotePeerInfo(), WakuStoreCodec)

    listenSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("2"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 2], ts=2),
      fakeWakuMessage(@[byte 3], ts=3),
      fakeWakuMessage(@[byte 4], ts=4),
      fakeWakuMessage(@[byte 5], ts=5),
      fakeWakuMessage(@[byte 6], ts=6),
      fakeWakuMessage(@[byte 7], ts=7),
      fakeWakuMessage(@[byte 8], ts=8),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("2"), ts=9)
    ]

    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_store_v1_messages(
                                some(DefaultPubsubTopic),
                                some(@[HistoryContentFilterRPC(contentTopic: DefaultContentTopic)]),
                                some(Timestamp(0)),
                                some(Timestamp(9)),
                                some(StorePagingOptions()))
    check:
      response.messages.len == 8
      response.pagingOptions.isNone()

    await server.stop()
    await server.closeWait()
    await node.stop()
    await listenSwitch.stop()

  asyncTest "check error response when peer-store-node is not available":
    let
      privkey = generateSecp256k1Key()
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")
      port = Port(0)
      node = newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

    await node.start()

    # RPC server setup
    let
      rpcPort = Port(8549)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installStoreApiHandlers(node, server)
    server.start()

    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], ts=0),
      fakeWakuMessage(@[byte 9], ts=9)
    ]
    for msg in msgList:
      require (waitFor driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    var response:StoreResponse
    var jsonError:JsonNode
    try:
      response = await client.get_waku_v2_store_v1_messages(
                                  some(DefaultPubsubTopic),
                                  some(@[HistoryContentFilterRPC(contentTopic: DefaultContentTopic)]),
                                  some(Timestamp(0)),
                                  some(Timestamp(9)),
                                  some(StorePagingOptions()))
    except ValueError:
      jsonError = parseJson(getCurrentExceptionMsg())

    check:
      $jsonError["code"] == "-32000"
      jsonError["message"].getStr() == "get_waku_v2_store_v1_messages raised an exception"
      jsonError["data"].getStr() == "no suitable remote store peers"

    # Now configure a store-peer
    let
      key = generateEcdsaKey()
      peer = PeerInfo.new(key)

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    listenSwitch.mount(node.wakuStore)

    node.peerManager.addServicePeer(listenSwitch.peerInfo.toRemotePeerInfo(),
                                    WakuStoreCodec)

    response = await client.get_waku_v2_store_v1_messages(
                                some(DefaultPubsubTopic),
                                some(@[HistoryContentFilterRPC(contentTopic: DefaultContentTopic)]),
                                some(Timestamp(0)),
                                some(Timestamp(9)),
                                some(StorePagingOptions()))
    check:
      response.messages.len == 2
      response.pagingOptions.isNone()

    await server.stop()
    await server.closeWait()
    await node.stop()
    await listenSwitch.stop()
