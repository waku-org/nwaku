{.used.}

import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  ../../waku/protocol/v2/[waku_relay, waku_filter, message_notifier],
  ../../waku/node/v2/waku_types,
  ../test_helpers, ./utils

procSuite "Waku Filter":

  asyncTest "handle filter":
    let
      proto = WakuFilter.init()
      subscription = proto.subscription()

    var subscriptions = initTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "pew")
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "pew2")

    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    let remoteSecKey = PrivateKey.random(ECDSA, rng[]).get()
    let remotePeerInfo = PeerInfo.init(
      remoteSecKey,
      [ma],
      ["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
    )

    var serverFut: Future[void]
    let msListen = newMultistream()

    msListen.addHandler(WakuFilterCodec, proto)
    proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
      await msListen.handle(conn)

    var transport1 = TcpTransport.init()
    serverFut = await transport1.listen(ma, connHandler)

    let msDial = newMultistream()
    let transport2: TcpTransport = TcpTransport.init()
    let conn = await transport2.dial(transport1.ma)

    var rpc = FilterRequest(contentFilter: @[waku_filter.ContentFilter(topics: @["pew", "pew2"])], topic: "topic")
    discard await msDial.select(conn, WakuFilterCodec)
    await conn.writeLP(rpc.encode().buffer)

    await sleepAsync(2.seconds)

    subscriptions.notify("topic", msg)
    subscriptions.notify("topic", msg2)
    
    var message = await conn.readLp(64*1024)

    let response = MessagePush.init(message)
    let res = response.value
    check:
      res.messages.len() == 1
      res.messages[0] == msg
