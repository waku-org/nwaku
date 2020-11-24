import
  std/[unittest, options, tables, sets],
  chronos, chronicles, stew/shims/net as stewNet, stew/byteutils,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/[crypto, secp],
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/message,
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  eth/keys,
  ../../waku/v2/protocol/[message_notifier],
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/node/message_store,
  ../../waku/v2/node/wakunode2,
  ../test_helpers, ./utils,
  ../../waku/v2/waku_types

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

  asyncTest "Update accounting state after store operations":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60001))
      contentTopic = ContentTopic(1)
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    # Start nodes and mount protocols
    await node1.start()
    node1.mountStore()
    node1.mountSwap()
    await node2.start()
    node2.mountStore()
    node1.mountSwap()

    await node2.subscriptions.notify("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.peerInfo)

    proc storeHandler(response: HistoryResponse) {.gcsafe, closure.} =
      debug "storeHandler hit"
      check:
        response.messages[0] == message
      completionFut.complete(true)

    await node1.query(HistoryQuery(topics: @[contentTopic]), storeHandler)

    # TODO Other node accounting field not set
    # info "node2", msgs = node2.wakuSwap.accounting # crashes
    # node2.wakuSwap.accounting[node1.peerInfo.peerId] = -1

    check:
      (await completionFut.withTimeout(5.seconds)) == true
      # Accounting table updated with one message credit
      node1.wakuSwap.accounting[node2.peerInfo.peerId] == 1
    await node1.stop()
    await node2.stop()
