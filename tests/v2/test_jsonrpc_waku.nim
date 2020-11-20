import
  std/[unittest, options, sets, tables, os, strutils],
  stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  libp2p/standard_setup,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/message,
  ../../waku/v2/waku_types,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/jsonrpc/[waku_jsonrpc, waku_jsonrpc_types],
  ../../waku/v2/protocol/[waku_store, message_notifier],
  ../test_helpers

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
const sigPath = sourceDir / ParDir / ParDir / "waku" / "v2" / "node" / "jsonrpc" / "waku_jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigPath)

suite "Waku v2 JSON-RPC API":

  asyncTest "get_waku_v2_store_query":
    const defaultTopic = "/waku/2/default-waku/proto"
    const testCodec = "/waku/2/default-waku/codec"

    # WakuNode setup
    let
      rng = crypto.newRng()
      privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")
      port = Port(9000)
      node = WakuNode.init(privkey, bindIp, port, some(extIp), some(port))

    waitFor node.start()

    waitFor node.mountRelay(@[defaultTopic])

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    setupWakuRPCAPI(node, server)
    server.start()

    # WakuStore setup
    let
      key = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
    
    node.mountStore()
    let
      subscription = node.wakuStore.subscription()
    
    var listenSwitch = newStandardSwitch(some(key))
    discard waitFor listenSwitch.start()

    node.wakuStore.setPeer(listenSwitch.peerInfo)

    listenSwitch.mount(node.wakuStore)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions[testCodec] = subscription

    # Now prime it with some history before tests
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic(2)),
        WakuMessage(payload: @[byte 1], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 2], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 3], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 4], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 5], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 6], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 7], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 8], contentTopic: ContentTopic(1)), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic(2))]

    for wakuMsg in msgList:
      waitFor subscriptions.notify(defaultTopic, wakuMsg)

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    let response = await client.get_waku_v2_store_query(HistoryQueryAPI(topics: @[ContentTopic(1)]))
    check:
      response.messages.len() == 8
      response.pagingInfo.isNone
      
    server.stop()
    server.close()
    waitfor node.stop()
