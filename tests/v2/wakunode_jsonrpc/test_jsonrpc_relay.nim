{.used.}

import
  std/[options, sequtils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/common/base64,
  ../../../waku/v2/waku_core,
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/node/message_cache,
  ../../../waku/v2/waku_node,
  ../../../waku/v2/node/jsonrpc/relay/handlers as relay_api,
  ../../../waku/v2/node/jsonrpc/relay/client as relay_api_client,
  ../../../waku/v2/waku_core,
  ../../../waku/v2/waku_relay,
  ../../../waku/v2/utils/compat,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode


proc newTestMessageCache(): relay_api.MessageCache =
  relay_api.MessageCache.init(capacity=30)


suite "Waku v2 JSON-RPC API - Relay":

  asyncTest "subscribe and unsubscribe from topics":
    ## Setup
    let node = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    await node.start()
    await node.mountRelay(topics = @[DefaultPubsubTopic])

    # JSON-RPC server
    let
      rpcPort = Port(8547)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(node, server, newTestMessageCache())
    server.start()

    # JSON-RPC client
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    ## Given
    let newTopics = @["test-topic1","test-topic2","test-topic3"]

    ## When
    # Subscribe to new topics
    let subResp = await client.post_waku_v2_relay_v1_subscriptions(newTopics)

    let subTopics = node.wakuRelay.subscribedTopics.toSeq()

    # Unsubscribe from new topics
    let unsubResp = await client.delete_waku_v2_relay_v1_subscriptions(newTopics)

    let unsubTopics = node.wakuRelay.subscribedTopics.toSeq()

    ## Then
    check:
      subResp == true
    check:
      # Node is now subscribed to default + new topics
      subTopics.len == 1 + newTopics.len
      DefaultPubsubTopic in subTopics
      newTopics.allIt(it in subTopics)

    check:
      unsubResp == true
    check:
      # Node is now unsubscribed from new topics
      unsubTopics.len == 1
      DefaultPubsubTopic in unsubTopics
      newTopics.allIt(it notin unsubTopics)

    await server.stop()
    await server.closeWait()

    await node.stop()

  asyncTest "publish message to topic":
    ## Setup
    let
      pubSubTopic = "test-jsonrpc-pubsub-topic"
      contentTopic = "test-jsonrpc-content-topic"

    # Relay nodes setup
    let
      srcNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      dstNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(srcNode.start(), dstNode.start())

    await srcNode.mountRelay(@[pubSubTopic])
    await dstNode.mountRelay(@[pubSubTopic])

    await srcNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])


    # RPC server (source node)
    let
      rpcPort = Port(8548)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(srcNode, server, newTestMessageCache())
    server.start()

    # JSON-RPC client
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    ## Given
    let message = fakeWakuMessage( payload= @[byte 72], contentTopic=contentTopic)

    let dstHandlerFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc dstHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      dstHandlerFut.complete((topic, msg))

    dstNode.subscribe(pubSubTopic, dstHandler)

    ## When
    let rpcMessage = WakuMessageRPC(
      payload: base64.encode(message.payload),
      contentTopic: some(message.contentTopic),
      timestamp: some(message.timestamp),
      version: some(message.version)
    )
    let response = await client.post_waku_v2_relay_v1_message(pubSubTopic, rpcMessage)

    ## Then
    require:
      response == true
      await dstHandlerFut.withTimeout(chronos.seconds(5))

    let (topic, msg) = dstHandlerFut.read()
    check:
      topic == pubSubTopic
      msg == message


    ## Cleanup
    await server.stop()
    await server.closeWait()
    await allFutures(srcNode.stop(), dstNode.stop())

  asyncTest "get latest messages received from topics cache":
    ## Setup
    let
      pubSubTopic = "test-jsonrpc-pubsub-topic"
      contentTopic = "test-jsonrpc-content-topic"

    # Relay nodes setup
    let
      srcNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      dstNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(srcNode.start(), dstNode.start())

    await srcNode.mountRelay(@[pubSubTopic])
    await dstNode.mountRelay(@[pubSubTopic])

    await srcNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])


    # RPC server (destination node)
    let
      rpcPort = Port(8548)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(dstNode, server, newTestMessageCache())
    server.start()

    # JSON-RPC client
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    ## Given
    let messages = @[
      fakeWakuMessage(payload= @[byte 70], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 71], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 72], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 73], contentTopic=contentTopic)
    ]

    ## When
    for msg in messages:
      await srcNode.publish(pubSubTopic, msg)

    await sleepAsync(200.millis)

    let dstMessages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)

    ## Then
    check:
      dstMessages.len == 4
      dstMessages[2].payload == base64.encode(messages[2].payload)
      dstMessages[2].contentTopic.get() == messages[2].contentTopic
      dstMessages[2].timestamp.get() == messages[2].timestamp
      dstMessages[2].version.get() == messages[2].version

    ## Cleanup
    await server.stop()
    await server.closeWait()
    await allFutures(srcNode.stop(), dstNode.stop())


suite "Waku v2 JSON-RPC API - Relay (Private)":

  asyncTest "generate symmetric keys and encrypt/decrypt communication":
    let
      pubSubTopic = "test-relay-pubsub-topic"
      contentTopic = "test-relay-content-topic"

    let
      srcNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(0))
      relNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(0))
      dstNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(0))

    await allFutures(srcNode.start(), relNode.start(), dstNode.start())

    await srcNode.mountRelay(@[pubSubTopic])
    await relNode.mountRelay(@[pubSubTopic])
    await dstNode.mountRelay(@[pubSubTopic])

    await srcNode.connectToNodes(@[relNode.peerInfo.toRemotePeerInfo()])
    await relNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      srcRpcPort = Port(8554)
      srcTa = initTAddress(ValidIpAddress.init("127.0.0.1"), srcRpcPort)
      srcServer = newRpcHttpServer([srcTa])

    let srcMessageCache = newTestMessageCache()
    installRelayApiHandlers(srcNode, srcServer, srcMessageCache)
    installRelayPrivateApiHandlers(srcNode, srcServer, srcMessageCache)
    srcServer.start()

    let
      dstRpcPort = Port(8555)
      dstTa = initTAddress(ValidIpAddress.init("127.0.0.1"), dstRpcPort)
      dstServer = newRpcHttpServer([dstTa])

    let dstMessageCache = newTestMessageCache()
    installRelayApiHandlers(dstNode, dstServer, dstMessageCache)
    installRelayPrivateApiHandlers(dstNode, dstServer, dstMessageCache)
    dstServer.start()


    let srcClient = newRpcHttpClient()
    await srcClient.connect("127.0.0.1", srcRpcPort, false)

    let dstClient = newRpcHttpClient()
    await dstClient.connect("127.0.0.1", dstRpcPort, false)

    ## Given
    let
      payload = @[byte 38]
      payloadBase64 = base64.encode(payload)

    let message = WakuMessageRPC(
        payload: payloadBase64,
        contentTopic: some(contentTopic),
        timestamp: some(now()),
      )

    ## When
    let symkey = await dstClient.get_waku_v2_private_v1_symmetric_key()

    let posted = await srcCLient.post_waku_v2_private_v1_symmetric_message(pubSubTopic, message, symkey = (%symkey).getStr())
    require:
      posted

    await sleepAsync(100.millis)

    # Let's see if we can receive, and decrypt, this message on dstNode
    var messages = await dstClient.get_waku_v2_private_v1_symmetric_messages(pubSubTopic, symkey = (%symkey).getStr())
    check:
      messages.len == 1
      messages[0].payload == payloadBase64
      messages[0].contentTopic == message.contentTopic
      messages[0].timestamp == message.timestamp
      messages[0].version.get() == 1'u32

    # Ensure that read messages are cleared from cache
    messages = await dstClient.get_waku_v2_private_v1_symmetric_messages(pubSubTopic, symkey = (%symkey).getStr())
    check:
      messages.len == 0

    ## Cleanup
    await srcServer.stop()
    await srcServer.closeWait()
    await dstServer.stop()
    await dstServer.closeWait()

    await allFutures(srcNode.stop(), relNode.stop(), dstNode.stop())

  asyncTest "generate asymmetric keys and encrypt/decrypt communication":
    let
      pubSubTopic = "test-relay-pubsub-topic"
      contentTopic = "test-relay-content-topic"

    let
      srcNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(0))
      relNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(0))
      dstNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(0))

    await allFutures(srcNode.start(), relNode.start(), dstNode.start())

    await srcNode.mountRelay(@[pubSubTopic])
    await relNode.mountRelay(@[pubSubTopic])
    await dstNode.mountRelay(@[pubSubTopic])

    await srcNode.connectToNodes(@[relNode.peerInfo.toRemotePeerInfo()])
    await relNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      srcRpcPort = Port(8554)
      srcTa = initTAddress(ValidIpAddress.init("127.0.0.1"), srcRpcPort)
      srcServer = newRpcHttpServer([srcTa])

    let srcMessageCache = newTestMessageCache()
    installRelayApiHandlers(srcNode, srcServer, srcMessageCache)
    installRelayPrivateApiHandlers(srcNode, srcServer, srcMessageCache)
    srcServer.start()

    let
      dstRpcPort = Port(8555)
      dstTa = initTAddress(ValidIpAddress.init("127.0.0.1"), dstRpcPort)
      dstServer = newRpcHttpServer([dstTa])

    let dstMessageCache = newTestMessageCache()
    installRelayApiHandlers(dstNode, dstServer, dstMessageCache)
    installRelayPrivateApiHandlers(dstNode, dstServer, dstMessageCache)
    dstServer.start()


    let srcClient = newRpcHttpClient()
    await srcClient.connect("127.0.0.1", srcRpcPort, false)

    let dstClient = newRpcHttpClient()
    await dstClient.connect("127.0.0.1", dstRpcPort, false)

    ## Given
    let
      payload = @[byte 38]
      payloadBase64 = base64.encode(payload)

    let message = WakuMessageRPC(
        payload: payloadBase64,
        contentTopic: some(contentTopic),
        timestamp: some(now()),
      )

    ## When
    let keypair = await dstClient.get_waku_v2_private_v1_asymmetric_keypair()

    # Now publish and encrypt a message on srcNode using dstNode's public key
    let posted = await srcClient.post_waku_v2_private_v1_asymmetric_message(pubSubTopic, message, publicKey = (%keypair.pubkey).getStr())
    require:
      posted

    await sleepAsync(100.millis)

    # Let's see if we can receive, and decrypt, this message on dstNode
    var messages = await dstClient.get_waku_v2_private_v1_asymmetric_messages(pubSubTopic, privateKey = (%keypair.seckey).getStr())
    check:
      messages.len == 1
      messages[0].payload == payloadBase64
      messages[0].contentTopic == message.contentTopic
      messages[0].timestamp == message.timestamp
      messages[0].version.get() == 1'u32

    # Ensure that read messages are cleared from cache
    messages = await dstClient.get_waku_v2_private_v1_asymmetric_messages(pubSubTopic, privateKey = (%keypair.seckey).getStr())
    check:
      messages.len == 0

    ## Cleanup
    await srcServer.stop()
    await srcServer.closeWait()
    await dstServer.stop()
    await dstServer.closeWait()

    await allFutures(srcNode.stop(), relNode.stop(), dstNode.stop())

