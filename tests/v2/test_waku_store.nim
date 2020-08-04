import unittest, options, tables, sets, sequtils
import chronos, chronicles
import utils,
       libp2p/errors,
       libp2p/switch,
       libp2p/protobuf/minprotobuf,
       libp2p/stream/[bufferstream, connection],
       libp2p/crypto/crypto,
       libp2p/protocols/pubsub/floodsub
import ../../waku/protocol/v2/waku_protocol2

import ../test_helpers

procSuite "Waku Store":
  asyncTest "handle query":