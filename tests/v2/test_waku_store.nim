import unittest, options, tables, sets, sequtils
import chronos, chronicles
import utils,
       libp2p/errors,
       libp2p/switch,
       libp2p/protobuf/minprotobuf,
       libp2p/stream/[bufferstream, connection],
       libp2p/crypto/crypto,
       libp2p/protocols/pubsub/floodsub,
       libp2p/protocols/pubsub/rpc/message,
       libp2p/multistream,
       libp2p/transports/transport,
       libp2p/transports/tcptransport
import ../../waku/protocol/v2/[waku_relay, waku_store, filter]

import ../test_helpers

procSuite "Waku Store":

  test "encoding and decoding StoreRPC":
    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      msg = Message.init(peer, @[byte 1, 2, 3], "topic", 3, false)

      rpc = StoreRPC(query: @[HistoryQuery(requestID: 1, topics: @["foo"])], response: @[HistoryResponse(requestID: 1, messages: @[msg])])

    let buf = rpc.encode()

    let decode = StoreRPC.init(buf.buffer)

    check:
      decode.isErr == false
      decode.value == rpc

  asyncTest "handle query":
    let 
      proto = WakuStore.init()
      filter = proto.filter()

    var filters = initTable[string, Filter]()
    filters["test"] = filter

    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      msg = Message.init(peer, @[byte 1, 2, 3], "topic", 3, false)
      msg2 = Message.init(peer, @[byte 1, 2, 3], "topic2", 4, false)

    filters.notify(msg)
    filters.notify(msg2)

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

    var rpc = StoreRPC(query: @[HistoryQuery(requestID: 1, topics: @["topic"])])
    discard await msDial.select(conn, WakuStoreCodec)
    await conn.writeLP(rpc.encode().buffer)

    var message = await conn.readLp(64*1024)
    let response = StoreRPC.init(message)

    check:
      response.isErr == false
      response.value.response[0].requestID == rpc.query[0].requestID
      response.value.response[0].messages.len() == 1
      response.value.response[0].messages[0] == msg
