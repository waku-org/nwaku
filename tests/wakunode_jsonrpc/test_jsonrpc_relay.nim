{.used.}

import
  std/[options, sequtils, tempfiles],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/common/base64,
  ../../../waku/waku_core,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_api/message_cache,
  ../../../waku/waku_node,
  ../../../waku/waku_api/jsonrpc/relay/handlers as relay_api,
  ../../../waku/waku_api/jsonrpc/relay/client as relay_api_client,
  ../../../waku/waku_core,
  ../../../waku/waku_relay,
  ../../../waku/waku_rln_relay,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

suite "Waku v2 JSON-RPC API - Relay":

  asyncTest "subscribe and unsubscribe from topics":
    ## Setup
    let node = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    await node.start()
    await node.mountRelay(@[])

    # JSON-RPC server
    let
      rpcPort = Port(8547)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    let cache = MessageCache[string].init(capacity=30)
    installRelayApiHandlers(node, server, cache)
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
      subTopics.len == newTopics.len
      newTopics.allIt(it in subTopics)

    check:
      unsubResp == true
    check:
      # Node is now unsubscribed from new topics
      unsubTopics.len == 0
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

    await srcNode.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1")))

    await dstNode.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_2")))

    await srcNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])

    # RPC server (source node)
    let
      rpcPort = Port(8548)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    let cache = MessageCache[string].init(capacity=30)
    installRelayApiHandlers(srcNode, server, cache)
    server.start()

    # JSON-RPC client
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    ## Given
    let message = fakeWakuMessage( payload= @[byte 72], contentTopic=contentTopic)

    let dstHandlerFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc dstHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      dstHandlerFut.complete((topic, msg))

    dstNode.subscribe((kind: PubsubSub, topic: pubsubTopic), some(dstHandler))

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

    var (topic, msg) = dstHandlerFut.read()

    # proof is injected under the hood, we compare just the message
    msg.proof = @[]

    check:
      topic == pubSubTopic
      msg == message


    ## Cleanup
    await server.stop()
    await server.closeWait()
    await allFutures(srcNode.stop(), dstNode.stop())

  asyncTest "get latest messages received from pubsub topics cache":
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
    await dstNode.mountRelay(@[])

    await srcNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])

    # RPC server (destination node)
    let
      rpcPort = Port(8549)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    let cache = MessageCache[string].init(capacity=30)
    installRelayApiHandlers(dstNode, server, cache)
    server.start()

    # JSON-RPC client
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    discard await client.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    ## Given
    let messages = @[
      fakeWakuMessage(payload= @[byte 70], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 71], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 72], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 73], contentTopic=contentTopic)
    ]

    ## When
    for msg in messages:
      await srcNode.publish(some(pubSubTopic), msg)

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

  asyncTest "get latest messages received from content topics cache":
    ## Setup
    let contentTopic = DefaultContentTopic

    # Relay nodes setup
    let
      srcNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      dstNode = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(srcNode.start(), dstNode.start())

    let shard = getShard(contentTopic).expect("Valid Shard")

    await srcNode.mountRelay(@[shard])
    await dstNode.mountRelay(@[])

    await srcNode.connectToNodes(@[dstNode.peerInfo.toRemotePeerInfo()])

    # RPC server (destination node)
    let
      rpcPort = Port(8550)
      ta = initTAddress(ValidIpAddress.init("0.0.0.0"), rpcPort)
      server = newRpcHttpServer([ta])

    let cache = MessageCache[string].init(capacity=30)
    installRelayApiHandlers(dstNode, server, cache)
    server.start()

    # JSON-RPC client
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    discard await client.post_waku_v2_relay_v1_auto_subscriptions(@[contentTopic])

    ## Given
    let messages = @[
      fakeWakuMessage(payload= @[byte 70], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 71], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 72], contentTopic=contentTopic),
      fakeWakuMessage(payload= @[byte 73], contentTopic=contentTopic)
    ]

    ## When
    for msg in messages:
      await srcNode.publish(none(PubsubTopic), msg)

    await sleepAsync(200.millis)

    let dstMessages = await client.get_waku_v2_relay_v1_auto_messages(contentTopic)

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