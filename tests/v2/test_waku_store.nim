{.used.}

import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/message,
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  ../../waku/protocol/v2/[waku_store, message_notifier],
  ../../waku/node/v2/waku_message,
  ../test_helpers, ./utils

procSuite "Waku Store":
  asyncTest "handle query":
    let 
      proto = WakuStore.init()
      subscription = proto.subscription()

    var subscriptions = initTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic")
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")

    subscriptions.notify("foo", msg)
    subscriptions.notify("foo", msg2)

    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    let remoteSecKey = PrivateKey.random(ECDSA, rng[]).get()
    let remotePeerInfo = PeerInfo.init(
      remoteSecKey,
      [ma],
      ["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
    )

    var serverFut: Future[void]
    let msListen = newMultistream()

    msListen.addHandler(WakuStoreCodec, proto)
    proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
      await msListen.handle(conn)

    var transport1 = TcpTransport.init()
    serverFut = await transport1.listen(ma, connHandler)

    let msDial = newMultistream()
    let transport2: TcpTransport = TcpTransport.init()
    let conn = await transport2.dial(transport1.ma)

    var rpc = HistoryQuery(uuid: "1234", topics: @["topic"])
    discard await msDial.select(conn, WakuStoreCodec)
    await conn.writeLP(rpc.encode().buffer)

    var message = await conn.readLp(64*1024)
    let response = HistoryResponse.init(message)

    check:
      response.isErr == false
      response.value.uuid == rpc.uuid
      response.value.messages.len() == 1
      response.value.messages[0] == msg
