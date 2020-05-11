## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import unittest
import sequtils, tables, options, sets, strutils
import chronos, chronicles
import libp2p/protocols/pubsub/pubsub,
       libp2p/protocols/pubsub/pubsubpeer,
       libp2p/protocols/pubsub/floodsub,
       libp2p/connection

logScope:
    topic = "WakuSub"

#For spike
const WakuSubCodec* = "/wakusub/0.0.1"

#const wakuVersionStr = "2.0.0-alpha1"

# So this should already have floodsub table, seen, as well as peerinfo, topics, peers, etc
# How do we verify that in nim?
type
  WakuSub* = ref object of FloodSub
    # XXX: just playing
    text*: string

method init(w: WakuSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/wakusub/0.0.1``, etc...
    ##

    echo "Incoming WakuSub connection"
    # Defer to parent object (I think)
    await w.handleConn(conn, proto)

  # XXX: Handler hijack FloodSub here?
  w.handler = handler
  w.codec = WakuSubCodec

method initPubSub*(w: WakuSub) =
  echo "initWakuSub"
  w.text = "Foobar"
  w.init()

# Here floodsub field is a topic to remote peer map
# We also have a seen message forwarded to peers

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

# Can also do in-line here


