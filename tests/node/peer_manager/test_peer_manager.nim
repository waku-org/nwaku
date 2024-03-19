import
  chronicles,
  std/[options, tables, strutils],
  stew/shims/net,
  chronos,
  testutils/unittests

import
  ../../../waku/[node/waku_node, waku_core],
  ../../waku_lightpush/[lightpush_utils],
  ../../testlib/[wakucore, wakunode, futures, testasync],
  ../../../../waku/node/peer_manager/peer_manager

suite "Peer Manager":
  suite "onPeerMetadata":
    var
      listenPort {.threadvar.}: Port
      listenAddress {.threadvar.}: IpAddress
      serverKey {.threadvar.}: PrivateKey
      clientKey {.threadvar.}: PrivateKey
      clusterId {.threadvar.}: uint64
      shardTopic0 {.threadvar.}: string
      shardTopic1 {.threadvar.}: string

    asyncSetup:
      listenPort = Port(0)
      listenAddress = ValidIpAddress.init("0.0.0.0")
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      clusterId = 1
      shardTopic0 = "/waku/2/rs/" & $clusterId & "/0"
      shardTopic1 = "/waku/2/rs/" & $clusterId & "/1"

    asyncTest "light client is not disconnected":
      # Given two nodes with the same shardId
      let
        server =
          newTestWakuNode(serverKey, listenAddress, listenPort, topics = @[shardTopic0])
        client =
          newTestWakuNode(clientKey, listenAddress, listenPort, topics = @[shardTopic1])

      # And both mount metadata and filter
      discard client.mountMetadata(0) # clusterId irrelevant, overridden by topic
      discard server.mountMetadata(0) # clusterId irrelevant, overridden by topic
      await client.mountFilterClient()
      await server.mountFilter()

      # And both nodes are started
      waitFor allFutures(server.start(), client.start())
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When making an operation that triggers onPeerMetadata
      discard await client.filterSubscribe(
        some("/waku/2/default-waku/proto"), "waku/lightpush/1", serverRemotePeerInfo
      )
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

    asyncTest "relay with same shardId is not disconnected":
      # Given two nodes with the same shardId
      let
        server =
          newTestWakuNode(serverKey, listenAddress, listenPort, topics = @[shardTopic0])
        client =
          newTestWakuNode(clientKey, listenAddress, listenPort, topics = @[shardTopic0])

      # And both mount metadata and relay
      discard client.mountMetadata(0) # clusterId irrelevant, overridden by topic
      discard server.mountMetadata(0) # clusterId irrelevant, overridden by topic
      await client.mountRelay()
      await server.mountRelay()

      # And both nodes are started
      waitFor allFutures(server.start(), client.start())
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When making an operation that triggers onPeerMetadata
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic"))
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

    asyncTest "relay with different shardId is disconnected":
      # Given two nodes with different shardIds
      let
        server =
          newTestWakuNode(serverKey, listenAddress, listenPort, topics = @[shardTopic0])
        client =
          newTestWakuNode(clientKey, listenAddress, listenPort, topics = @[shardTopic1])

      # And both mount metadata and relay
      discard client.mountMetadata(0) # clusterId irrelevant, overridden by topic
      discard server.mountMetadata(0) # clusterId irrelevant, overridden by topic
      await client.mountRelay()
      await server.mountRelay()

      # And both nodes are started
      waitFor allFutures(server.start(), client.start())
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When making an operation that triggers onPeerMetadata
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic"))
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        not server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        not client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)
