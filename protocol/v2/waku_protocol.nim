## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import sequtils, tables, options, sets, strutils
import chronos, chronicles
import ../../vendor/nim-libp2p/libp2p/protocols/pubsub/pubsub,
       ../../vendor/nim-libp2p/libp2p/protocols/pubsub/pubsubpeer,
       ../../vendor/nim-libp2p/libp2p/protocols/pubsub/floodsub

logScope:
    topic = "WakuSub"

# For spike
const WakuSubCodec* = "/WakuSub/0.0.1"

#const wakuVersionStr = "2.0.0-alpha1"

# So this should already have floodsub table, seen, as well as peerinfo, topics, peers, etc
# How do we verify that in nim?
type
  WakuSub* = ref object of FloodSub
    # XXX: just playing
    text*: string

# method subscribeTopic
# method handleDisconnect
# method rpcHandler
# method init
# method publish
# method unsubscribe
# method initPubSub

# To defer to parent object something like:
# procCall PubSub(f).publish(topic, data)

# Then we should be able to write tests like floodsub test
