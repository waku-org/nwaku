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
       libp2p/protocols/pubsub/rpc/[messages, message],
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
  debug "init"
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/wakusub/0.0.1``, etc...
    ##

    echo "Incoming WakuSub connection"
    assert(w of FloodSub)
    echo "asserted w of floodsub"
    assert(w of PubSub)
    echo "asserted w of pubsub"
    # Defer to parent object (I think)
    # This isn't hit, possibly cause double link here?
    await w.handleConn(conn, proto)

  # XXX: Handler hijack FloodSub here?
  w.handler = handler
  w.codec = WakuSubCodec

#
method initPubSub*(w: WakuSub) =
  debug "initWakuSub"
  w.text = "Foobar"
  echo "w.text", w.text
  # XXX
  procCall FloodSub(w).initPubSub()
  w.init()

method subscribeTopic*(w: WakuSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.gcsafe.} =
  debug "subscribeTopic"
  procCall FloodSub(w).subscribeTopic(topic, subscribe, peerId)

method handleDisconnect*(w: WakuSub, peer: PubSubPeer) {.async.} =
  debug "handleDisconnect NYI"

method rpcHandler*(w: WakuSub,
                   peer: PubSubPeer,
                   rpcMsgs: seq[RPCMsg]) {.async.} =
  debug "rpcHandler"
  await procCall FloodSub(w).rpcHandler(peer, rpcMsgs)

method publish*(w: WakuSub,
                topic: string,
                data: seq[byte]) {.async.} =
  debug "publish"
  await procCall FloodSub(w).publish(topic, data)

method unsubscribe*(w: WakuSub,
                    topics: seq[TopicPair]) {.async.} =
  debug "unsubscribe"
  await procCall FloodSub(w).unsubscribe(topics)
