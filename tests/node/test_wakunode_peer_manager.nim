{.used.}

import
  os,
  std/[options, tables],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  # chronos/timer,
  chronicles,
  libp2p/[peerstore, crypto/crypto, multiaddress]

from times import getTime, toUnix

import
  ../../../waku/[
    waku_core,
    node/peer_manager,
    node/waku_node,
    waku_enr/sharding,
    waku_discv5,
    waku_filter_v2/common,
    waku_relay/protocol,
  ],
  ../testlib/[wakucore, wakunode, testasync, testutils],
  ../waku_enr/utils,
  ../waku_archive/archive_utils,
  ../waku_discv5/utils,
  ./peer_manager/peer_store/utils,
  ./utils

const DEFAULT_PROTOCOLS: seq[string] =
  @["/ipfs/id/1.0.0", "/libp2p/autonat/1.0.0", "/libp2p/circuit/relay/0.2.0/hop"]

let
  listenIp = ValidIpAddress.init("0.0.0.0")
  listenPort = Port(0)

suite "Peer Manager":
  var
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic

  var
    server {.threadvar.}: WakuNode
    serverPeerStore {.threadvar.}: PeerStore
    client {.threadvar.}: WakuNode
    clientPeerStore {.threadvar.}: PeerStore

  var
    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    serverPeerId {.threadvar.}: PeerId
    clientRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerId {.threadvar.}: PeerId

  asyncSetup:
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, listenIp, listenPort)
    serverPeerStore = server.peerManager.peerStore
    client = newTestWakuNode(clientKey, listenIp, listenPort)
    clientPeerStore = client.peerManager.peerStore

    await allFutures(server.start(), client.start())

    serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
    serverPeerId = serverRemotePeerInfo.peerId
    clientRemotePeerInfo = client.switch.peerInfo.toRemotePeerInfo()
    clientPeerId = clientRemotePeerInfo.peerId

  asyncTeardown:
    await allFutures(server.stop(), client.stop())

  suite "Peer Connectivity, Management, and Store":
    asyncTest "Peer Connection Validation":
      # When a client connects to a server
      await client.connectToNodes(@[serverRemotePeerInfo])

      # Then the server should have the client in its peer store
      check:
        clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected
        serverPeerStore.get(clientPeerId).connectedness == Connectedness.Connected

    asyncTest "Graceful Handling of Non-Existent Peers":
      # Given a non existent RemotePeerInfo
      let
        privKey = generateSecp256k1Key()
        extIp = "127.0.0.1"
        tcpPort = 61500u16
        udpPort = 9000u16
        nonExistentRecord = newTestEnrRecord(
          privKey = privKey, extIp = extIp, tcpPort = tcpPort, udpPort = udpPort
        )
        nonExistentRemotePeerInfo = nonExistentRecord.toRemotePeerInfo().value()

      # When a client connects to the non existent peer
      await client.connectToNodes(@[nonExistentRemotePeerInfo])

      let parsedRemotePeerInfo = clientPeerStore.get(nonExistentRemotePeerInfo.peerId)
      check:
        parsedRemotePeerInfo.connectedness == CannotConnect
        parsedRemotePeerInfo.lastFailedConn <= Moment.init(getTime().toUnix, Second)
        parsedRemotePeerInfo.numberFailedConn == 1

    suite "Peer Store Pruning":
      asyncTest "Capacity is not exceeded":
        # Given the client's peer store has a capacity of 1
        clientPeerStore.capacity = 1

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then no peers are removed
        check:
          clientPeerStore.peers().len == 1

      asyncTest "Capacity is not exceeded but some peers are unhealthy":
        # Given the client's peer store has a capacity of 1
        clientPeerStore.capacity = 1

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as not connected
        client.peerManager.peerStore[ConnectionBook].book[serverPeerId] = CannotConnect

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 1

      asyncTest "Capacity is exceeded but all peers are healthy":
        # Given the client's peer store has a capacity of 0
        clientPeerStore.capacity = 0

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then no peers are removed
        check:
          clientPeerStore.peers().len == 1

      asyncTest "Failed connections":
        # Given the client's peer store has a capacity of 0 and maxFailedAttempts of 1
        clientPeerStore.capacity = 0
        client.peerManager.maxFailedAttempts = 1

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as having 1 failed connection
        client.peerManager.peerStore[NumberFailedConnBook].book[serverPeerId] = 1

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 0

      asyncTest "Shardless":
        # Given the client's peer store has a capacity of 0
        clientPeerStore.capacity = 0

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as not connected
        client.peerManager.peerStore[ConnectionBook].book[serverPeerId] = CannotConnect

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 0

      asyncTest "Higher than avg shard count":
        # Given the client's peer store has a capacity of 0
        clientPeerStore.capacity = 0

        # And the server's remote peer info contains the node's ENR
        serverRemotePeerInfo.enr = some(server.enr)

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as not connected
        # There's only one shard in the ENR so avg shards will be the same as the shard count; hence it will be purged.
        client.peerManager.peerStore[ConnectionBook].book[serverPeerId] = CannotConnect

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 0

    # suite "Handling Connections on Different Networks":
    #   asyncTest "Same cluster but different shard":
    #     # peer 1 is on cluster x - shard a  ; peer 2 is on cluster x - shard b

    #     # Given two extra clients
    #     let
    #       client2Key = generateSecp256k1Key()
    #       client3Key = generateSecp256k1Key()
    #       listenIp = ValidIpAddress.init("0.0.0.0")
    #       listenPort = Port(0)
    #       tcpPort = 61500u16
    #       udpPort = 9000u16
    #       client2 = newTestWakuNode(
    #         client2Key, listenIp, listenPort, topics = @["/waku/2/rs/1/0"]
    #       )
    #       client3 = newTestWakuNode(
    #         client3Key, listenIp, listenPort, topics = @["/waku/2/rs/1/1"]
    #       )

    #     await allFutures(client2.start(), client3.start())
    #     let
    #       wakuDiscv5n2 = newTestDiscv5(
    #         client2Key,
    #         "0.0.0.0",
    #         tcpPort,
    #         client2.netConfig.discv5UdpPort,
    #         client2.enr,
    #         peerManager = some(client2.peerManager),
    #       )
    #       wakuDiscv5n3 = newTestDiscv5(
    #         client3Key,
    #         "0.0.0.0",
    #         61501u16,
    #         9001u16,
    #         client3.enr,
    #         peerManager = some(client3.peerManager),
    #       )
    #     waitFor allFutures(wakuDiscv5n2.start(), wakuDiscv5n3.start())

    #     # await client2.connectToNodes(@[client3.switch.peerInfo.toRemotePeerInfo()])

    #     await sleepAsync(15.seconds)

    #     check:
    #       client2.peerManager.peerStore.peers().len == 1
    #       client3.peerManager.peerStore.peers().len == 1

    #     await allFutures(client2.stop(), client3.stop())

    #   asyncTest "Different cluster but same shard":
    #     # peer 1 is on cluster x - shard a  ; peer 2 is on cluster y - shard a
    #     discard

    #   asyncTest "Different cluster and different shard":
    #     # peer 1 is on cluster x - shard a  ; peer 2 is on cluster y - shard b
    #     discard

    #   asyncTest "Same cluster with multiple shards (one shared)":
    #     # peer 1 is on cluster x - shard [a,b,c]  ; peer 2 is on cluster x - shard [c, d, e]
    #     discard

    suite "Enforcing Colocation Limits":
      asyncTest "Without colocation limits":
        # Given two extra clients
        let
          client2Key = generateSecp256k1Key()
          client3Key = generateSecp256k1Key()
          # listenIp = ValidIpAddress.init("0.0.0.0")
          # listenPort = Port(0)
          client2 = newTestWakuNode(client2Key, listenIp, listenPort)
          client3 = newTestWakuNode(client3Key, listenIp, listenPort)

        await allFutures(client2.start(), client3.start())

        # And the client's peer manager has a colocation limit of 0
        server.peerManager.colocationLimit = 0

        await client.connectToNodes(@[serverRemotePeerInfo])
        await client2.connectToNodes(@[serverRemotePeerInfo])
        await client3.connectToNodes(@[serverRemotePeerInfo])

        check:
          serverPeerStore.peers().len == 3

        # Teardown
        await allFutures(client2.stop(), client3.stop())

      asyncTest "With colocation limits":
        # Given two extra clients
        let
          client2Key = generateSecp256k1Key()
          client3Key = generateSecp256k1Key()
          # listenIp = ValidIpAddress.init("0.0.0.0")
          # listenPort = Port(0)
          client2 = newTestWakuNode(client2Key, listenIp, listenPort)
          client3 = newTestWakuNode(client3Key, listenIp, listenPort)

        await allFutures(client2.start(), client3.start())

        # And the client's peer manager has a colocation limit of 0
        server.peerManager.colocationLimit = 1

        await client.connectToNodes(@[serverRemotePeerInfo])
        await client2.connectToNodes(@[serverRemotePeerInfo])
        await client3.connectToNodes(@[serverRemotePeerInfo])

        check:
          serverPeerStore.peers().len == 1

        # Teardown
        await allFutures(client2.stop(), client3.stop())

    suite "In-memory Data Structure Verification":
      # TODO: "peers.db"
      asyncTest "Cannot add self":
        # When trying to add self to the peer store
        client.peerManager.addPeer(clientRemotePeerInfo)

        # Then the peer store should not contain the client
        check:
          not clientPeerStore.peerExists(clientPeerId)

      asyncTest "Peer stored in peer store":
        # When adding a peer other than self to the peer store
        serverRemotePeerInfo.enr = some(server.enr)
        client.peerManager.addPeer(serverRemotePeerInfo)

        # Then the peer store should contain the peer
        check clientPeerStore.peerExists(serverPeerId)

        # And all the peer's information should be stored
        check:
          clientPeerStore[AddressBook][serverPeerId] == serverRemotePeerInfo.addrs
          # clientPeerStore[KeyBook][serverPeerId] == serverRemotePeerInfo.publicKey
          # clientPeerStore[SourceBook][serverPeerId] == UnknownOrigin
          # clientPeerStore[ProtoBook][serverPeerId] == serverRemotePeerInfo.protocols
          # clientPeerStore[ENRBook][serverPeerId].raw ==
          #   serverRemotePeerInfo.enr.get().raw

    suite "Protocol-Specific Peer Handling":
      asyncTest "Peer Protocol Support Verification - No waku protocols":
        await client.connectToNodes(@[serverRemotePeerInfo])

        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.get(serverPeerId).protocols == DEFAULT_PROTOCOLS

      asyncTest "Peer Protocol Support Verification (Before Connection)":
        await server.mountRelay()
        await server.mountFilter()

        await client.connectToNodes(@[serverRemotePeerInfo])

        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.get(serverPeerId).protocols ==
            DEFAULT_PROTOCOLS & @[WakuRelayCodec, WakuFilterSubscribeCodec]

      xasyncTest "Peer Protocol Support Verification (After Connection)":
        # TODO: Mounted protocols after connection are not being registered
        await client.connectToNodes(@[serverRemotePeerInfo])

        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.get(serverPeerId).protocols == DEFAULT_PROTOCOLS

        await server.mountRelay()
        await server.mountFilter()

        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.get(serverPeerId).protocols ==
            DEFAULT_PROTOCOLS & @[WakuRelayCodec, WakuFilterSubscribeCodec]

      xasyncTest "Service-Specific Peer Addition":
        # echo "\n\n"
        # echo serverRemotePeerInfo.protocols
        # echo server.switch.peerInfo.toRemotePeerInfo().protocols
        # await server.mountRelay()
        # echo serverRemotePeerInfo.protocols
        # echo server.switch.peerInfo.toRemotePeerInfo().protocols
        # echo "\n\n"

        let
          server2Key = generateSecp256k1Key()
          server2 = newTestWakuNode(server2Key, listenIp, listenPort)

        let
          server2RemotePeerInfo = server2.switch.peerInfo.toRemotePeerInfo()
          server2PeerId = server2RemotePeerInfo.peerId
        await server2.mountRelay()
        await server2.start()
        # await server2.mountFilter()
        await server2.mountRelay()

        await sleepAsync(3.seconds)

        # echo "~~~~~~~~"
        # echo clientPeerStore.get(serverPeerId).protocols
        # # echo serverRemotePeerInfo.protocols
        # # echo server.switch.peerInfo.toRemotePeerInfo().protocols
        # echo "~"
        # await client.connectToNodes(@[serverRemotePeerInfo])
        # echo "~"
        # echo clientPeerStore.get(serverPeerId).protocols
        # echo serverRemotePeerInfo.protocols
        # echo server.switch.peerInfo.toRemotePeerInfo().protocols
        echo "~~~~~~~~"
        # await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])
        # await client.connectToNodes(@[server2.switch.peerInfo.toRemotePeerInfo()])
        echo clientPeerStore.get(server2PeerId).protocols
        # echo server2RemotePeerInfo.protocols
        # echo server2.switch.peerInfo.toRemotePeerInfo().protocols
        echo "~"
        await client.connectToNodes(@[server2RemotePeerInfo])
        echo "~"
        echo clientPeerStore.get(server2PeerId).protocols
        # echo server2RemotePeerInfo.protocols
        # echo server2.switch.peerInfo.toRemotePeerInfo().protocols
        echo "~~~~~~~~"

        check:
          # clientPeerStore.peerExists(serverPeerId)
          # clientPeerStore.get(serverPeerId).protocols ==
          #   DEFAULT_PROTOCOLS & @[WakuRelayCodec]

          clientPeerStore.peerExists(server2PeerId)
          clientPeerStore.get(server2PeerId).protocols ==
            DEFAULT_PROTOCOLS & @[WakuRelayCodec]

        # Cleanup
        await server2.stop()

    suite "Tracked Peer Metadata":
      template chainedComparison(a: untyped, b: untyped, c: untyped): bool =
        a == b and b == c

      xasyncTest "Metadata Recording":
        # When adding a peer other than self to the peer store
        serverRemotePeerInfo.enr = some(server.enr)
        client.peerManager.addPeer(serverRemotePeerInfo)

        # Then the peer store should contain the peer
        check clientPeerStore.peerExists(serverPeerId)

        # And all the peer's information should be stored
        check:
          clientPeerStore[AddressBook][serverPeerId] == serverRemotePeerInfo.addrs
          clientPeerStore[ENRBook][serverPeerId].raw ==
            serverRemotePeerInfo.enr.get().raw
          chainedComparison(
            clientPeerStore[ProtoBook][serverPeerId],
            serverRemotePeerInfo.protocols,
            DEFAULT_PROTOCOLS,
          )
          chainedComparison(
            clientPeerStore[AgentBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.agent,
            "nim-libp2p/0.0.1",
          )
          chainedComparison(
            clientPeerStore[ProtoVersionBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.protoVersion,
            "ipfs/0.1.0",
          )
          clientPeerStore[KeyBook][serverPeerId] == serverRemotePeerInfo.publicKey
          chainedComparison(
            clientPeerStore[ConnectionBook][serverPeerId],
            serverRemotePeerInfo.connectedness,
            NOT_CONNECTED,
          )
          chainedComparison(
            clientPeerStore[DisconnectBook][serverPeerId],
            serverRemotePeerInfo.disconnectTime,
            0,
          )
          chainedComparison(
            clientPeerStore[SourceBook][serverPeerId],
            serverRemotePeerInfo.origin,
            UnknownOrigin,
          )
          chainedComparison(
            clientPeerStore[DirectionBook][serverPeerId],
            serverRemotePeerInfo.direction,
            UnknownDirection,
          )
          chainedComparison(
            clientPeerStore[LastFailedConnBook][serverPeerId],
            serverRemotePeerInfo.lastFailedConn,
            Moment.init(0, Second),
          )
          chainedComparison(
            clientPeerStore[NumberFailedConnBook][serverPeerId],
            serverRemotePeerInfo.numberFailedConn,
            0,
          )

      xasyncTest "Metadata Accuracy":
        # Given a peer other than self is added to the peer store
        let
          server2Key = generateSecp256k1Key()
          server2 = newTestWakuNode(server2Key, listenIp, listenPort)
          server2RemotePeerInfo = server2.switch.peerInfo.toRemotePeerInfo()
          server2PeerId = server2RemotePeerInfo.peerId

        await server2.start()

        # When the client connects to both servers
        await client.connectToNodes(@[serverRemotePeerInfo, server2RemotePeerInfo])

        echo serverRemotePeerInfo.addrs
        echo server2RemotePeerInfo.addrs
        echo clientPeerStore[AddressBook][serverPeerId]
        echo clientPeerStore[AddressBook][server2PeerId]
        # Then the peer store should contain the peers
        check:
          # Server
          clientPeerStore[AddressBook][serverPeerId] == serverRemotePeerInfo.addrs
          clientPeerStore[ENRBook][serverPeerId].raw ==
            serverRemotePeerInfo.enr.get().raw
          chainedComparison(
            clientPeerStore[ProtoBook][serverPeerId],
            serverRemotePeerInfo.protocols,
            DEFAULT_PROTOCOLS,
          )
          chainedComparison(
            clientPeerStore[AgentBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.agent,
            "nim-libp2p/0.0.1",
          )
          chainedComparison(
            clientPeerStore[ProtoVersionBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.protoVersion,
            "ipfs/0.1.0",
          )
          clientPeerStore[KeyBook][serverPeerId] == serverRemotePeerInfo.publicKey
          chainedComparison(
            clientPeerStore[ConnectionBook][serverPeerId],
            serverRemotePeerInfo.connectedness,
            NOT_CONNECTED,
          )
          chainedComparison(
            clientPeerStore[DisconnectBook][serverPeerId],
            serverRemotePeerInfo.disconnectTime,
            0,
          )
          chainedComparison(
            clientPeerStore[SourceBook][serverPeerId],
            serverRemotePeerInfo.origin,
            UnknownOrigin,
          )
          chainedComparison(
            clientPeerStore[DirectionBook][serverPeerId],
            serverRemotePeerInfo.direction,
            UnknownDirection,
          )
          chainedComparison(
            clientPeerStore[LastFailedConnBook][serverPeerId],
            serverRemotePeerInfo.lastFailedConn,
            Moment.init(0, Second),
          )
          chainedComparison(
            clientPeerStore[NumberFailedConnBook][serverPeerId],
            serverRemotePeerInfo.numberFailedConn,
            0,
          )

          # Server 2
          clientPeerStore[AddressBook][server2PeerId] == server2RemotePeerInfo.addrs
          clientPeerStore[ENRBook][server2PeerId].raw ==
            server2RemotePeerInfo.enr.get().raw
          chainedComparison(
            clientPeerStore[ProtoBook][server2PeerId],
            server2RemotePeerInfo.protocols,
            DEFAULT_PROTOCOLS,
          )
          # chainedComparison(
          #   clientPeerStore[AgentBook][server2PeerId], # FIXME: Not assigned
          #   server2RemotePeerInfo.agent,
          #   "nim-libp2p/0.0.1",
          # )
          # chainedComparison(
          #   clientPeerStore[ProtoVersionBook][server2PeerId], # FIXME: Not assigned
          #   server2RemotePeerInfo.protoVersion,
          #   "ipfs/0.1.0",
          # )
          clientPeerStore[KeyBook][serverPeerId] == server2RemotePeerInfo.publicKey
          chainedComparison(
            clientPeerStore[ConnectionBook][server2PeerId],
            server2RemotePeerInfo.connectedness,
            NOT_CONNECTED,
          )
          chainedComparison(
            clientPeerStore[DisconnectBook][server2PeerId],
            server2RemotePeerInfo.disconnectTime,
            0,
          )
          chainedComparison(
            clientPeerStore[SourceBook][server2PeerId],
            server2RemotePeerInfo.origin,
            UnknownOrigin,
          )
          chainedComparison(
            clientPeerStore[DirectionBook][server2PeerId],
            server2RemotePeerInfo.direction,
            UnknownDirection,
          )
          chainedComparison(
            clientPeerStore[LastFailedConnBook][server2PeerId],
            server2RemotePeerInfo.lastFailedConn,
            Moment.init(0, Second),
          )
          chainedComparison(
            clientPeerStore[NumberFailedConnBook][server2PeerId],
            server2RemotePeerInfo.numberFailedConn,
            0,
          )

      suite "Peer Connectivity States":
        asyncTest "State Tracking & Transition":
          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.NotConnected

          await client.connectToNodes(@[serverRemotePeerInfo])

          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected

          await server.switch.disconnect(clientPeerId)
          server.peerManager.peerStore.delete(clientPeerId)

          echo "#"
          echo serverPeerStore.get(clientPeerId).connectedness
          echo clientPeerStore.get(serverPeerId).connectedness
          echo "#"

      suite "Automatic Reconnection":
        xasyncTest "Automatic Reconnection Implementation":
          await server.mountRelay()
          # await client.mountRelay()

          # await client.connectToNodes(@[serverRemotePeerInfo])

          # check:
          #   clientPeerStore.peerExists(serverPeerId)
          #   clientPeerStore.get(serverPeerId).protocols == DEFAULT_PROTOCOLS

          await client.connectToNodes(@[serverRemotePeerInfo])
          echo clientPeerStore.get(serverPeerId).protocols
          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected
            serverPeerStore.get(clientPeerId).connectedness == Connectedness.Connected

          # echo "#"
          # echo WakuRelayCodec
          # echo clientPeerStore.get(serverPeerId).protocols
          # echo clientPeerStore.get(serverPeerId).connectedness
          # echo serverPeerStore.get(clientPeerId).protocols
          # echo serverPeerStore.get(clientPeerId).connectedness
          # echo "#"

          await server.switch.disconnect(clientPeerId)
          await client.switch.disconnect(serverPeerId)
          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected
            serverPeerStore.get(clientPeerId).connectedness == Connectedness.CanConnect
          echo "\n\n\n\n\n\n\n\n\n\n"
          echo "#"
          echo clientPeerStore.get(serverPeerId).connectedness
          echo serverPeerStore.get(clientPeerId).connectedness
          echo "#"

          echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          await client.peerManager.reconnectPeers(WakuRelayCodec)
          echo "#"
          # echo clientPeerStore.get(serverPeerId).connectedness
          # echo serverPeerStore.get(clientPeerId).connectedness
          echo clientPeerStore.get(serverPeerId).protocols
          echo serverPeerStore.get(clientPeerId).protocols
          echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          await server.peerManager.reconnectPeers(WakuRelayCodec)
          echo "#"
          # echo clientPeerStore.get(serverPeerId).connectedness
          # echo serverPeerStore.get(clientPeerId).connectedness
          echo clientPeerStore.get(serverPeerId).protocols
          echo serverPeerStore.get(clientPeerId).protocols
          echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          await sleepAsync(5.seconds)

          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected
            serverPeerStore.get(clientPeerId).connectedness == Connectedness.Connected

        xasyncTest "Automatic Reconnection Implementation (After client restart)":
          await server.mountRelay()

          await client.connectToNodes(@[serverRemotePeerInfo])
          await sleepAsync(1.seconds)
          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected
            serverPeerStore.get(clientPeerId).connectedness == Connectedness.Connected

          waitFor allFutures(client.stop(), server.stop())
          await sleepAsync(1.seconds)

          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.CanConnect
            serverPeerStore.get(clientPeerId).connectedness == Connectedness.CanConnect

          waitFor allFutures(client.start(), server.start())
          echo clientPeerStore.get(serverPeerId).connectedness
          echo serverPeerStore.get(clientPeerId).connectedness
          await sleepAsync(1.seconds)
          await client.peerManager.reconnectPeers(WakuRelayCodec)
          await server.peerManager.reconnectPeers(WakuRelayCodec)
          echo clientPeerStore.get(serverPeerId).connectedness
          echo serverPeerStore.get(clientPeerId).connectedness
          await sleepAsync(1.seconds)
          check:
            clientPeerStore.get(serverPeerId).connectedness == Connectedness.Connected
            serverPeerStore.get(clientPeerId).connectedness == Connectedness.Connected

        asyncTest "Backoff Period Respect":
          discard

const baseDbPath = "./peers.test.db"
proc cleanupDb() =
  os.removeFile(baseDbPath)
  os.removeFile(baseDbPath & "-shm")
  os.removeFile(baseDbPath & "-wal")

suite "Persistence Check":
  asyncTest "PeerStorage exists":
    # Given an on-disk peer db exists, with a peer in it
    let
      clientPeerStorage = newTestWakuPeerStorage(some(baseDbPath))
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      # listenIp = ValidIpAddress.init("0.0.0.0")
      # listenPort = Port(0)
      server = newTestWakuNode(serverKey, listenIp, listenPort)
      serverPeerStore = server.peerManager.peerStore
      client = newTestWakuNode(
        clientKey, listenIp, listenPort, peerStorage = clientPeerStorage
      )
      clientPeerStore = client.peerManager.peerStore

    await allFutures(server.start(), client.start())

    await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])
    check:
      clientPeerStore.peers().len == 1

    await allFutures(server.stop(), client.stop())

    # When initializing a new client with the same peer storage
    let
      newClientPeerStorage = newTestWakuPeerStorage(some(baseDbPath))
      newClient = newTestWakuNode(
        clientKey, listenIp, listenPort, peerStorage = newClientPeerStorage
      )
      newClientPeerStore = newClient.peerManager.peerStore

    await newClient.start()

    # Then the new client should have the same peer in its peer store
    check:
      newClientPeerStore.peers().len == 1

    # Cleanup
    await newClient.stop()
    cleanupDb()

  asyncTest "PeerStorage exists but no data":
    # Given no peer db exists
    cleanupDb()

    # When creating a new server, and a client with on-disk peer storage
    let
      clientPeerStorage = newTestWakuPeerStorage(some(baseDbPath))
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      # listenIp = ValidIpAddress.init("0.0.0.0")
      # listenPort = Port(0)
      server = newTestWakuNode(serverKey, listenIp, listenPort)
      serverPeerStore = server.peerManager.peerStore
      client = newTestWakuNode(
        clientKey, listenIp, listenPort, peerStorage = clientPeerStorage
      )
      clientPeerStore = client.peerManager.peerStore

    await allFutures(server.start(), client.start())

    # Then the client's peer store should be empty
    check:
      clientPeerStore.peers().len == 0

    # Cleanup
    await allFutures(server.stop(), client.stop())
    cleanupDb()

  asyncTest "PeerStorage not exists":
    # When creating a new server and client without peer storage
    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      # listenIp = ValidIpAddress.init("0.0.0.0")
      # listenPort = Port(0)
      server = newTestWakuNode(serverKey, listenIp, listenPort)
      serverPeerStore = server.peerManager.peerStore
      client = newTestWakuNode(clientKey, listenIp, listenPort)
      clientPeerStore = client.peerManager.peerStore

    await allFutures(server.start(), client.start())

    # Then the client's peer store should be empty
    check:
      clientPeerStore.peers().len == 0

    # Cleanup
    await allFutures(server.stop(), client.stop())
