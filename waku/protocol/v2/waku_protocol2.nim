## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import strutils
import chronos, chronicles
import libp2p/protocols/pubsub/pubsub,
       libp2p/protocols/pubsub/pubsubpeer,
       libp2p/protocols/pubsub/floodsub,
       libp2p/protocols/pubsub/gossipsub,
       libp2p/protocols/pubsub/rpc/[messages],
       libp2p/stream/connection

import metrics

declarePublicGauge connected_peers, "number of peers in the pool" # XXX
declarePublicGauge total_messages, "number of messages received"

logScope:
    topic = "WakuSub"

const WakuSubCodec* = "/wakusub/2.0.0-alpha1"

type
  WakuSub* = ref object of GossipSub
    # XXX: just playing
    text*: string
    pubsub*: Pubsub

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

  # XXX: Handler hijack GossipSub here?
  w.handler = handler
  w.codec = WakuSubCodec

method initPubSub*(w: WakuSub) =
  debug "initWakuSub"
  w.text = "Foobar"
  debug "w.text", text = w.text

  # Using GossipSub
  let gossipsub = true
  if gossipsub:
    w.pubsub = GossipSub(w)
  else:
    w.pubsub = FloodSub(w)
    
  procCall w.pubsub.initPubSub()

  w.init()

method subscribe*(w: WakuSub,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  debug "subscribe", topic=topic
  # XXX: Pubsub really

  # XXX: This is what is called, I think
  await procCall w.pubsub.subscribe(topic, handler)


# Subscribing a peer to a specified topic
method subscribeTopic*(w: WakuSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.async, gcsafe.} =
  proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    info "Hit NOOP handler", topic

  debug "subscribeTopic", topic=topic, subscribe=subscribe, peerId=peerId

  await procCall w.pubsub.subscribeTopic(topic, subscribe, peerId)

  # XXX: This should distingish light and etc node
  # NOTE: Relay subscription
  # TODO: If peer is light node
  info "about to call subscribe"
  await w.subscribe(topic, handler)




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

  await procCall w.pubsub.rpcHandler(peer, rpcMsgs)
  # XXX: here

method publish*(w: WakuSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  debug "publish", topic=topic

  await procCall w.pubsub.publish(topic, data)

method unsubscribe*(w: WakuSub,
                    topics: seq[TopicPair]) {.async.} =
  debug "unsubscribe"
  await procCall w.pubsub.unsubscribe(topics)

# GossipSub specific methods
method start*(w: WakuSub) {.async.} =
  debug "start"
  await procCall w.pubsub.start()

method stop*(w: WakuSub) {.async.} =
  debug "stop"

  await procCall w.pubsub.stop()
