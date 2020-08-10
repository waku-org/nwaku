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
import ../../waku/protocol/v2/[waku_protocol2, waku_store, filter]

import ../test_helpers

procSuite "Waku Store":
  asyncTest "handle query":
    let proto = WakuStore.init()
    let filter = proto.filter()

    var filters = initTable[string, Filter]()
    filters["test"] = filter

    let msg = Message.init(PeerInfo(), @[byte 1, 2, 3], "topic", 3, false)
    filters.notify(msg)

    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    let remoteSecKey = PrivateKey.random(ECDSA, rng[]).get()
    let remotePeerInfo = PeerInfo.init(remoteSecKey,
                                        [ma],
                                        ["/test/proto1/1.0.0",
                                         "/test/proto2/1.0.0"])
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

    var rpc = StoreRPC(query: @[HistoryQuery(topics: @["topic"])])
    #await conn.write(WakuStoreCodec)
    await conn.writeLP(rpc.encode().buffer)

    var message = await conn.readLp(64*1024)
    var response = StoreRPC.init(message)
    echo response
    ##conn.writeLp()

    ##var message = await conn.readLp(64*1024)

