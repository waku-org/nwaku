## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import
  chronos, chronicles, metrics,
  libp2p/protocols/pubsub/[pubsub, floodsub, gossipsub],
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/stream/connection,
  ../waku_types

declarePublicGauge total_messages, "number of messages received"

logScope:
    topics = "wakurelay"

const WakuRelayCodec* = "/vac/waku/relay/2.0.0-beta1"

method init*(w: WakuRelay) =
  debug "init"
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/wakusub/0.0.1``, etc...
    ##

    debug "Incoming WakuRelay connection"
    await w.handleConn(conn, proto)

  # XXX: Handler hijack GossipSub here?
  w.handler = handler
  w.codec = WakuRelayCodec

method initPubSub*(w: WakuRelay) =
  debug "initWakuRelay"

  # Not using GossipSub
  # XXX: FloodSub subscribe doesn't work
  w.gossipEnabled = true

  if w.gossipEnabled:
    procCall GossipSub(w).initPubSub()
  else:
    procCall FloodSub(w).initPubSub()

  w.init()

method subscribe*(w: WakuRelay,
                  pubSubTopic: string,
                  handler: TopicHandler) {.async.} =
  debug "subscribe", pubSubTopic=pubSubTopic
  if w.gossipEnabled:
    await procCall GossipSub(w).subscribe(pubSubTopic, handler)
  else:
    await procCall FloodSub(w).subscribe(pubSubTopic, handler)

method publish*(w: WakuRelay,
                pubSubTopic: string,
                message: seq[byte]
               ): Future[int] {.async.} =
  debug "publish", pubSubTopic=pubSubTopic, message=message

  if w.gossipEnabled:
    return await procCall GossipSub(w).publish(pubSubTopic, message)
  else:
    return await procCall FloodSub(w).publish(pubSubTopic, message)

method unsubscribe*(w: WakuRelay,
                    topics: seq[TopicPair]) {.async.} =
  debug "unsubscribe"
  if w.gossipEnabled:
    await procCall GossipSub(w).unsubscribe(topics)
  else:
    await procCall FloodSub(w).unsubscribe(topics)

method unsubscribeAll*(w: WakuRelay,
                       pubSubTopic: string) {.async.} =
  debug "unsubscribeAll"
  if w.gossipEnabled:
    await procCall GossipSub(w).unsubscribeAll(pubSubTopic)
  else:
    await procCall FloodSub(w).unsubscribeAll(pubSubTopic)

# GossipSub specific methods --------------------------------------------------
method start*(w: WakuRelay) {.async.} =
  debug "start"
  if w.gossipEnabled:
    await procCall GossipSub(w).start()
  else:
    await procCall FloodSub(w).start()

method stop*(w: WakuRelay) {.async.} =
  debug "stop"
  if w.gossipEnabled:
    await procCall GossipSub(w).stop()
  else:
    await procCall FloodSub(w).stop()
