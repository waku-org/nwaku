{.used.}

import
  std/[options, tables, sets],
  stew/byteutils,
  stew/shims/net as stewNet, 
  testutils/unittests,
  chronos, 
  chronicles, 
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/[crypto, secp],
  libp2p/switch,
  eth/keys
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/utils/peers,
  ../test_helpers, 
  ./utils,
  ./testlib/common


procSuite "Waku SWAP Accounting":
  test "Handshake Encode/Decode":
    let
      beneficiary = @[byte 0, 1, 2]
      handshake = Handshake(beneficiary: beneficiary)
      pb = handshake.encode()

    let decodedHandshake = Handshake.init(pb.buffer)

    check:
      decodedHandshake.isErr == false
      decodedHandshake.get().beneficiary == beneficiary

  test "Cheque Encode/Decode":
    let
      amount = 1'u32
      date = 9000'u32
      beneficiary = @[byte 0, 1, 2]
      cheque = Cheque(beneficiary: beneficiary, amount: amount, date: date)
      pb = cheque.encode()

    let decodedCheque = Cheque.init(pb.buffer)

    check:
      decodedCheque.isErr == false
      decodedCheque.get() == cheque

  # TODO: To do this reliably we need access to contract node
  # With current logic state isn't updated because of bad cheque
  # Consider moving this test to e2e test, and/or move swap module to be on by default
  asyncTest "Update accounting state after store operations":
    ## Setup
    let
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60102))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60100))

    await allFutures(client.start(), server.start())

    await server.mountSwap()
    await server.mountStore(store=StoreQueueRef.new())
    await client.mountSwap()
    await client.mountStore()
    client.mountStoreClient()

    client.wakuSwap.setPeer(server.peerInfo.toRemotePeerInfo())
    server.wakuSwap.setPeer(client.peerInfo.toRemotePeerInfo())
    
    client.setStorePeer(server.peerInfo.toRemotePeerInfo())
    server.setStorePeer(client.peerInfo.toRemotePeerInfo())

    ## Given
    let message = fakeWakuMessage()
    require server.wakuStore.store.put(DefaultPubsubTopic, message).isOk()

    let serverPeer = server.peerInfo.toRemotePeerInfo()
    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)])

    ## When
    let queryRes = await client.query(rpc, peer=serverPeer)

    ## Then
    check queryRes.isOk()

    let response = queryRes.get()
    check:
      response.messages == @[message]

    check:
      client.wakuSwap.accounting[server.peerInfo.peerId] == 1
      server.wakuSwap.accounting[client.peerInfo.peerId] == -1
    
    ## Cleanup
    await allFutures(client.stop(), server.stop())


  # This test will only Be checked if in Mock mode
  # TODO: Add cheque here
  asyncTest "Update accounting state after sending cheque":
    ## Setup
    let
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60202))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60200))
    
    # Define the waku swap Config for this test
    let swapConfig = SwapConfig(mode: SwapMode.Mock, paymentThreshold: 1, disconnectThreshold: -1)

    # Start nodes and mount protocols
    await allFutures(client.start(), server.start())
    await server.mountSwap(swapConfig)
    await server.mountStore(store=StoreQueueRef.new())
    await client.mountSwap(swapConfig)
    await client.mountStore()
    client.mountStoreClient()

    client.wakuSwap.setPeer(server.peerInfo.toRemotePeerInfo())
    server.wakuSwap.setPeer(client.peerInfo.toRemotePeerInfo())

    client.setStorePeer(server.peerInfo.toRemotePeerInfo())
    server.setStorePeer(client.peerInfo.toRemotePeerInfo())
    
    ## Given
    let message = fakeWakuMessage()
    require server.wakuStore.store.put(DefaultPubsubTopic, message).isOk()
    
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)])

    ## When
    # TODO: Handshakes - for now we assume implicit, e2e still works for PoC
    let res1 = await client.query(rpc, peer=serverPeer)
    let res2 = await client.query(rpc, peer=serverPeer)

    require:
      res1.isOk()
      res2.isOk()

    ## Then
    check:
      # Accounting table updated with credit and debit, respectively
      # After sending a cheque the balance is partially adjusted
      client.wakuSwap.accounting[server.peerInfo.peerId] == 1
      server.wakuSwap.accounting[client.peerInfo.peerId] == -1

    ## Cleanup
    await allFutures(client.stop(), server.stop())
