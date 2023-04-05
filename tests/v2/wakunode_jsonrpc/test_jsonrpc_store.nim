{.used.}

import
  std/[options, times],
  stew/shims/net as stewNet,
  chronicles,
  testutils/unittests,
  eth/keys,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/node/waku_node,
  ../../../waku/v2/node/jsonrpc/store/handlers as store_api,
  ../../../waku/v2/node/jsonrpc/store/client as store_api_client,
  ../../../waku/v2/protocol/waku_message,
  ../../../waku/v2/protocol/waku_archive,
  ../../../waku/v2/protocol/waku_archive/driver/queue_driver,
  ../../../waku/v2/protocol/waku_store,
  ../../../waku/v2/protocol/waku_store/rpc,
  ../../../waku/v2/utils/peers,
  ../../../waku/v2/utils/time,
  ../../v2/testlib/common,
  ../../v2/testlib/waku2


proc put(store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage): Result[void, string] =
  let
    digest = waku_archive.computeDigest(message)
    receivedTime = if message.timestamp > 0: message.timestamp
                  else: getNanosecondTime(getTime().toUnixFloat())

  store.put(pubsubTopic, message, digest, receivedTime)

procSuite "Waku v2 JSON-RPC API - Store":
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)
    node = WakuNode.new(privkey, bindIp, port, some(extIp), some(port))

  asyncTest "query a node and retrieve historical messages":
    await node.start()

    await node.mountRelay()

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
    node.mountArchive(some(driver), none(MessageValidator), none(RetentionPolicy))
    await node.mountStore()
    node.mountStoreClient()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    node.peerManager.addServicePeer(listenSwitch.peerInfo.toRemotePeerInfo(), WakuStoreCodec)

    listenSwitch.mount(node.wakuRelay)
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
      require driver.put(DefaultPubsubTopic, msg).isOk()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_store_v1_messages(some(DefaultPubsubTopic), some(@[HistoryContentFilterRPC(contentTopic: DefaultContentTopic)]), some(Timestamp(0)), some(Timestamp(9)), some(StorePagingOptions()))
    check:
      response.messages.len() == 8
      response.pagingOptions.isNone()

    await server.stop()
    await server.closeWait()

    await node.stop()
