{.used.}

import
  std/[options, tables, sets],
  testutils/unittests,
  chronos, chronicles, stew/shims/net as stewNet, stew/byteutils,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/[crypto, secp],
  libp2p/switch,
  eth/keys,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/utils/peers,
  ../test_helpers, ./utils

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

  # TODO To do this reliably we need access to contract node
  # With current logic state isn't updated because of bad cheque
  # Consider moving this test to e2e test, and/or move swap module to be on by default
  asyncTest "Update accounting state after store operations":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60001))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    # Start nodes and mount protocols
    await node1.start()
    node1.mountSwap()
    node1.mountStore(persistMessages = true)
    await node2.start()
    node2.mountSwap()
    node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    node1.wakuSwap.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    node2.wakuSwap.setPeer(node1.switch.peerInfo.toRemotePeerInfo())

    proc storeHandler(response: HistoryResponse) {.gcsafe, closure.} =
      debug "storeHandler hit"
      check:
        response.messages[0] == message
      completionFut.complete(true)

    await node1.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic)]), storeHandler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
      # Accounting table updated with credit and debit, respectively
      node1.wakuSwap.accounting[node2.switch.peerInfo.peerId] == 1
      node2.wakuSwap.accounting[node1.switch.peerInfo.peerId] == -1
    await node1.stop()
    await node2.stop()

  # TODO Add cheque here
  # This test will only Be checked if in Mock mode
  asyncTest "Update accounting state after sending cheque":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60001))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var futures = [newFuture[bool](), newFuture[bool]()]

    # Define the waku swap Config for this test
    let swapConfig = SwapConfig(mode: SwapMode.Mock, paymentThreshold: 1, disconnectThreshold: -1)

    # Start nodes and mount protocols
    await node1.start()
    node1.mountSwap(swapConfig)
    node1.mountStore(persistMessages = true)
    await node2.start()
    node2.mountSwap(swapConfig)
    node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    node1.wakuSwap.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    node2.wakuSwap.setPeer(node1.switch.peerInfo.toRemotePeerInfo())

    proc handler1(response: HistoryResponse) {.gcsafe, closure.} =
      futures[0].complete(true)
    proc handler2(response: HistoryResponse) {.gcsafe, closure.} =
      futures[1].complete(true)

    # TODO Handshakes - for now we assume implicit, e2e still works for PoC
    await node1.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic)]), handler1)
    await node1.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic)]), handler2)

    check:
      (await allFutures(futures).withTimeout(5.seconds)) == true
      # Accounting table updated with credit and debit, respectively
      # After sending a cheque the balance is partially adjusted
      node1.wakuSwap.accounting[node2.switch.peerInfo.peerId] == 1
      node2.wakuSwap.accounting[node1.switch.peerInfo.peerId] == -1
    await node1.stop()
    await node2.stop()
