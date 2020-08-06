import unittest, options, tables, sets, sequtils
import chronos, chronicles
import utils,
       libp2p/errors,
       libp2p/switch,
       libp2p/protobuf/minprotobuf,
       libp2p/stream/[bufferstream, connection],
       libp2p/crypto/crypto,
       libp2p/protocols/pubsub/floodsub,
       libp2p/protocols/pubsub/rpc/message
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