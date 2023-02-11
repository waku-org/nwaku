{.used.}

import
  std/[options, sequtils, times],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/v1/node/rpc/hexstrings,
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/node/message_cache,
  ../../../waku/v2/node/waku_node,
  ../../../waku/v2/node/jsonrpc/relay/handlers as relay_api,
  ../../../waku/v2/node/jsonrpc/relay/client as relay_api_client,
  ../../../waku/v2/protocol/waku_message,
  ../../../waku/v2/protocol/waku_relay,
  ../../../waku/v2/utils/compat,
  ../../../waku/v2/utils/peers,
  ../../../waku/v2/utils/time,
  ../testlib/waku2


proc newTestMessageCache(): relay_api.MessageCache =
  relay_api.MessageCache.init(capacity=30)


procSuite "Waku v2 JSON-RPC API - Relay":
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)
    node = WakuNode.new(privkey, bindIp, port, some(extIp), some(port))

  asyncTest "subscribe, unsubscribe and publish":
    await node.start()

    await node.mountRelay(topics = @[DefaultPubsubTopic])

    # RPC server setup
    let
      rpcPort = Port(8547)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(node, server, newTestMessageCache())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    check:
      # At this stage the node is only subscribed to the default topic
      node.wakuRelay.subscribedTopics.toSeq().len == 1

    # Subscribe to new topics
    let newTopics = @["1","2","3"]
    var response = await client.post_waku_v2_relay_v1_subscriptions(newTopics)

    check:
      # Node is now subscribed to default + new topics
      node.wakuRelay.subscribedTopics.toSeq().len == 1 + newTopics.len
      response == true

    # Publish a message on the default topic
    response = await client.post_waku_v2_relay_v1_message(DefaultPubsubTopic, WakuRelayMessage(payload: @[byte 1], contentTopic: some(DefaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))

    check:
      # @TODO poll topic to verify message has been published
      response == true

    # Unsubscribe from new topics
    response = await client.delete_waku_v2_relay_v1_subscriptions(newTopics)

    check:
      # Node is now unsubscribed from new topics
      node.wakuRelay.subscribedTopics.toSeq().len == 1
      response == true

    await server.stop()
    await server.closeWait()

    await node.stop()

  asyncTest "get latest messages":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = WakuNode.new(nodeKey1, bindIp, Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = WakuNode.new(nodeKey2, bindIp, Port(0))
      nodeKey3 = generateSecp256k1Key()
      node3 = WakuNode.new(nodeKey3, bindIp, Port(0), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = DefaultContentTopic
      payload1 = @[byte 9]
      message1 = WakuMessage(payload: payload1, contentTopic: contentTopic)
      payload2 = @[byte 8]
      message2 = WakuMessage(payload: payload2, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # RPC server setup
    let
      rpcPort = Port(8548)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    # Let's connect to node 3 via the API
    installRelayApiHandlers(node3, server, newTestMessageCache())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    # First see if we can retrieve messages published on the default topic (node is already subscribed)
    await node2.publish(DefaultPubsubTopic, message1)

    await sleepAsync(100.millis)

    var messages = await client.get_waku_v2_relay_v1_messages(DefaultPubsubTopic)

    check:
      messages.len == 1
      messages[0].contentTopic == contentTopic
      messages[0].payload == payload1

    # Ensure that read messages are cleared from cache
    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)
    check:
      messages.len == 0

    # Now try to subscribe using API

    var response = await client.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(100.millis)

    check:
      # Node is now subscribed to pubSubTopic
      response == true

    # Now publish a message on node1 and see if we receive it on node3
    await node1.publish(pubSubTopic, message2)

    await sleepAsync(100.millis)

    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)

    check:
      messages.len == 1
      messages[0].contentTopic == contentTopic
      messages[0].payload == payload2

    # Ensure that read messages are cleared from cache
    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)
    check:
      messages.len == 0

    await server.stop()
    await server.closeWait()

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "generate asymmetric keys and encrypt/decrypt communication":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = WakuNode.new(nodeKey1, bindIp, Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = WakuNode.new(nodeKey2, bindIp, Port(0))
      nodeKey3 = generateSecp256k1Key()
      node3 = WakuNode.new(nodeKey3, bindIp, Port(0), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = DefaultContentTopic
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic), timestamp: some(getNanosecondTime(epochTime())))
      topicCache = newTestMessageCache()

    await node1.start()
    await node1.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      rpcPort1 = Port(8554)
      ta1 = initTAddress(bindIp, rpcPort1)
      server1 = newRpcHttpServer([ta1])
      rpcPort3 = Port(8555)
      ta3 = initTAddress(bindIp, rpcPort3)
      server3 = newRpcHttpServer([ta3])

    # Let's connect to nodes 1 and 3 via the API
    installRelayPrivateApiHandlers(node1, server1, newTestMessageCache())
    installRelayPrivateApiHandlers(node3, server3, topicCache)
    installRelayApiHandlers(node3, server3, topicCache)
    server1.start()
    server3.start()

    let client1 = newRpcHttpClient()
    await client1.connect("127.0.0.1", rpcPort1, false)

    let client3 = newRpcHttpClient()
    await client3.connect("127.0.0.1", rpcPort3, false)

    # Let's get a keypair for node3

    let keypair = await client3.get_waku_v2_private_v1_asymmetric_keypair()

    # Now try to subscribe on node3 using API

    let sub = await client3.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(100.millis)

    check:
      # node3 is now subscribed to pubSubTopic
      sub

    # Now publish and encrypt a message on node1 using node3's public key
    let posted = await client1.post_waku_v2_private_v1_asymmetric_message(pubSubTopic, message, publicKey = (%keypair.pubkey).getStr())
    check:
      posted

    await sleepAsync(100.millis)

    # Let's see if we can receive, and decrypt, this message on node3
    var messages = await client3.get_waku_v2_private_v1_asymmetric_messages(pubSubTopic, privateKey = (%keypair.seckey).getStr())

    check:
      messages.len == 1
      messages[0].contentTopic.get == contentTopic
      messages[0].payload == payload

    # Ensure that read messages are cleared from cache
    messages = await client3.get_waku_v2_private_v1_asymmetric_messages(pubSubTopic, privateKey = (%keypair.seckey).getStr())
    check:
      messages.len == 0

    await server1.stop()
    await server1.closeWait()
    await server3.stop()
    await server3.closeWait()

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "generate symmetric keys and encrypt/decrypt communication":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = WakuNode.new(nodeKey1, bindIp, Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = WakuNode.new(nodeKey2, bindIp, Port(0))
      nodeKey3 = generateSecp256k1Key()
      node3 = WakuNode.new(nodeKey3, bindIp, Port(0), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = DefaultContentTopic
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic), timestamp: some(getNanosecondTime(epochTime())))
      topicCache = newTestMessageCache()

    await node1.start()
    await node1.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[DefaultPubsubTopic, pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      rpcPort1 = Port(8556)
      ta1 = initTAddress(bindIp, rpcPort1)
      server1 = newRpcHttpServer([ta1])
      rpcPort3 = Port(8557)
      ta3 = initTAddress(bindIp, rpcPort3)
      server3 = newRpcHttpServer([ta3])

    # Let's connect to nodes 1 and 3 via the API
    installRelayPrivateApiHandlers(node1, server1, newTestMessageCache())
    installRelayPrivateApiHandlers(node3, server3, topicCache)
    installRelayApiHandlers(node3, server3, topicCache)
    server1.start()
    server3.start()

    let client1 = newRpcHttpClient()
    await client1.connect("127.0.0.1", rpcPort1, false)

    let client3 = newRpcHttpClient()
    await client3.connect("127.0.0.1", rpcPort3, false)

    # Let's get a symkey for node3

    let symkey = await client3.get_waku_v2_private_v1_symmetric_key()

    # Now try to subscribe on node3 using API

    let sub = await client3.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(100.millis)

    check:
      # node3 is now subscribed to pubSubTopic
      sub

    # Now publish and encrypt a message on node1 using node3's symkey
    let posted = await client1.post_waku_v2_private_v1_symmetric_message(pubSubTopic, message, symkey = (%symkey).getStr())
    check:
      posted

    await sleepAsync(100.millis)

    # Let's see if we can receive, and decrypt, this message on node3
    var messages = await client3.get_waku_v2_private_v1_symmetric_messages(pubSubTopic, symkey = (%symkey).getStr())

    check:
      messages.len == 1
      messages[0].contentTopic.get == contentTopic
      messages[0].payload == payload

    # Ensure that read messages are cleared from cache
    messages = await client3.get_waku_v2_private_v1_symmetric_messages(pubSubTopic, symkey = (%symkey).getStr())
    check:
      messages.len == 0

    await server1.stop()
    await server1.closeWait()
    await server3.stop()
    await server3.closeWait()

    await node1.stop()
    await node2.stop()
    await node3.stop()
