
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
import ../../waku/protocol/v2/[waku_relay, waku_filter, filter]

import ../test_helpers

procSuite "Waku Filter":

  test "encoding and decoding FilterRPC":
    let rpc = FilterRPC(filters: @[ContentFilter(topics: @["foo", "bar"])])

    let buf = rpc.encode()

    let decode = FilterRPC.init(buf.buffer)

    check:
      decode.isErr == false
      decode.value == rpc
