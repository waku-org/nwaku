## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import
  std/[strutils, tables],
  chronos, chronicles, metrics,
  libp2p/protocols/pubsub/[pubsub, pubsubpeer, floodsub, gossipsub],
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/stream/connection,
  ../../node/v2/waku_types,
  ./filter

declarePublicGauge total_messages, "number of messages received"

logScope:
    topic = "WakuRelay"

const WakuRelayCodec* = "/vac/waku/relay/2.0.0-alpha2"

type
  WakuRelay* = ref object of GossipSub
    gossipEnabled*: bool
    filters*: filter.Filters

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
  w.filters = initTable[string, filter.Filter]()

method initPubSub*(w: WakuRelay) =
  debug "initWakuRelay"

  # Not using GossipSub
  w.gossipEnabled = false

  if w.gossipEnabled:
    procCall GossipSub(w).initPubSub()
  else:
    procCall FloodSub(w).initPubSub()

  w.init()

method subscribe*(w: WakuRelay,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  debug "subscribe", topic=topic
  if w.gossipEnabled:
    await procCall GossipSub(w).subscribe(topic, handler)
  else:
    await procCall FloodSub(w).subscribe(topic, handler)

method publish*(w: WakuRelay,
                topic: string,
                message: seq[byte]
               ): Future[int] {.async.} =
  debug "publish", topic=topic

  if w.gossipEnabled:
    return await procCall GossipSub(w).publish(topic, message)
  else:
    return await procCall FloodSub(w).publish(topic, message)

method unsubscribe*(w: WakuRelay,
                    topics: seq[TopicPair]) {.async.} =
  debug "unsubscribe"
  if w.gossipEnabled:
    await procCall GossipSub(w).unsubscribe(topics)
  else:
    await procCall FloodSub(w).unsubscribe(topics)

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

proc addFilter*(w: WakuRelay, name: string, filter: filter.Filter) =
  w.filters.subscribe(name, filter)
