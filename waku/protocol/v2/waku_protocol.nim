## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import strutils
import chronos, chronicles
import libp2p/protocols/pubsub/pubsub,
       libp2p/protocols/pubsub/pubsubpeer,
       libp2p/protocols/pubsub/floodsub,
       libp2p/protocols/pubsub/rpc/[messages],
       libp2p/connection

import metrics

declarePublicGauge connected_peers, "number of peers in the pool" # XXX
declarePublicGauge total_messages, "number of messages received"

logScope:
    topic = "WakuSub"

#For spike
const WakuSubCodec* = "/wakusub/0.0.1"

#const wakuVersionStr = "2.0.0-alpha1"

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

    debug "Incoming WakuSub connection"
    # XXX: Increment connectedPeers counter, unclear if this is the right place tho
    # Where is the disconnect event?
    connected_peers.inc()
    await w.handleConn(conn, proto)

  # XXX: Handler hijack FloodSub here?
  w.handler = handler
  w.codec = WakuSubCodec

method initPubSub*(w: WakuSub) =
  debug "initWakuSub"
  w.text = "Foobar"
  debug "w.text", text = w.text
  # XXX
  procCall FloodSub(w).initPubSub()
  w.init()

method subscribe*(w: WakuSub,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  debug "subscribe", topic=topic
  # XXX: Pubsub really
  await procCall FloodSub(w).subscribe(topic, handler)

# Subscribing a peer to a specified topic
method subscribeTopic*(w: WakuSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.gcsafe.} =
  debug "subscribeTopic", topic=topic, subscribe=subscribe, peerId=peerId
  procCall FloodSub(w).subscribeTopic(topic, subscribe, peerId)

# TODO: Fix decrement connected peers here or somewhere else
method handleDisconnect*(w: WakuSub, peer: PubSubPeer) {.async.} =
  debug "handleDisconnect (NYI)"
  #connected_peers.dec()

method rpcHandler*(w: WakuSub,
                   peer: PubSubPeer,
                   rpcMsgs: seq[RPCMsg]) {.async.} =
  debug "rpcHandler"

  # XXX: Right place?
  total_messages.inc()
  await procCall FloodSub(w).rpcHandler(peer, rpcMsgs)

method publish*(w: WakuSub,
                topic: string,
                data: seq[byte]) {.async.} =
  debug "publish", topic=topic
  await procCall FloodSub(w).publish(topic, data)

method unsubscribe*(w: WakuSub,
                    topics: seq[TopicPair]) {.async.} =
  debug "unsubscribe"
  await procCall FloodSub(w).unsubscribe(topics)
