{.used.}

import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/[message, messages, protobuf],
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  ../../waku/protocol/v2/[waku_filter, filter],
  ../test_helpers, ./utils

procSuite "Waku Filter":

  test "encoding and decoding FilterRPC":
    let rpc = FilterRPC(filters: @[ContentFilter(topics: @["foo", "bar"])])

    let buf = rpc.encode()

    let decode = FilterRPC.init(buf.buffer)

    check:
      decode.isErr == false
      decode.value == rpc

  asyncTest "handle filter":
    let
      proto = WakuFilter.init()
      filter = proto.filter()

    var filters = initTable[string, Filter]()
    filters["test"] = filter

    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      msg = Message.init(peer, @[byte 1, 2, 3], "topic", 3, false)
      msg2 = Message.init(peer, @[byte 1, 2, 3], "topic2", 4, false)

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

    var rpc = FilterRPC(filters: @[ContentFilter(topics: @["topic"])])
    discard await msDial.select(conn, WakuFilterCodec)
    await conn.writeLP(rpc.encode().buffer)

    await sleepAsync(2.seconds)

    filters.notify(msg) 
    filters.notify(msg2)
    
    var message = await conn.readLp(64*1024)

    let response = protobuf.decodeMessage(initProtoBuffer(message))

    check:
      msg == response.value
