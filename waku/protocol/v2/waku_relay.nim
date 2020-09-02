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
    filters*: Filters

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
  w.filters = initTable[string, Filter]()
  w.codec = WakuRelayCodec

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

method subscribeTopic*(w: WakuRelay,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.async, gcsafe.} =
  proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    info "Hit NOOP handler", topic

    # Currently we are using the libp2p topic here.
    # This will need to be change to a Waku topic.

  debug "subscribeTopic", topic=topic, subscribe=subscribe, peerId=peerId

  if w.gossipEnabled:
    await procCall GossipSub(w).subscribeTopic(topic, subscribe, peerId)
  else:
    await procCall FloodSub(w).subscribeTopic(topic, subscribe, peerId)

  # XXX: This should distingish light and etc node
  # NOTE: Relay subscription
  # TODO: If peer is light node
  info "about to call subscribe"
  await w.subscribe(topic, handler)

method rpcHandler*(w: WakuRelay,
                   peer: PubSubPeer,
                   rpcMsgs: seq[RPCMsg]) {.async.} =
  debug "rpcHandler"

  # XXX: Right place?
  total_messages.inc()

  if w.gossipEnabled:
    await procCall GossipSub(w).rpcHandler(peer, rpcMsgs)
  else:
    await procCall FloodSub(w).rpcHandler(peer, rpcMsgs)
  # XXX: here
  
  for rpcs in rpcMsgs:
    for msg in rpcs.messages:
      w.filters.notify(msg)

method publish*(w: WakuRelay,
                topic: string,
                message: WakuMessage
               ): Future[int] {.async.} =
  debug "publish", topic=topic, contentTopic=message.contentTopic

  let data = message.encode().buffer

  if w.gossipEnabled:
    return await procCall GossipSub(w).publish(topic, data)
  else:
    return await procCall FloodSub(w).publish(topic, data)

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

proc addFilter*(w: WakuRelay, name: string, filter: Filter) =
  w.filters.subscribe(name, filter)
