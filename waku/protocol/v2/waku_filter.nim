import chronos, chronicles
import ./filter
import tables
import libp2p/protocols/pubsub/pubsub,
       libp2p/protocols/pubsub/pubsubpeer,
       libp2p/protocols/pubsub/floodsub,
       libp2p/protocols/pubsub/gossipsub,
       libp2p/protocols/pubsub/rpc/[messages, protobuf],
       libp2p/protocols/protocol,
       libp2p/protobuf/minprotobuf,
       libp2p/stream/connection

import metrics

import stew/results

const
  WakuFilterCodec* = "/vac/waku/filter/2.0.0-alpha2"

type
  WakuFilter* = ref object of LPProtocol

method init*(T: type WakuStore): T =
  var ws = WakuFilter()
  
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
      discard

  ws.handler = handle
  ws.codec = WakuFilterCodec
  result = ws
