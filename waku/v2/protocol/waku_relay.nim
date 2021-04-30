## Waku Relay module. Thin layer on top of GossipSub.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-relay.md
## for spec.

import
  std/[tables, sequtils, sets],
  chronos, chronicles, metrics,
  libp2p/protocols/pubsub/[pubsub, gossipsub],
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/stream/connection

logScope:
    topics = "wakurelay"

const
  WakuRelayCodec* = "/vac/waku/relay/2.0.0-beta2"
  DefaultKeepAlive = 5.minutes # 50% of the default chronosstream timeout duration

type
  WakuRelay* = ref object of GossipSub
    keepAlive*: bool

proc keepAlive*(w: WakuRelay) {.async.} =
  while w.keepAlive:
    # Keep all mesh peers alive when idle
    trace "Running keepalive"

    for topic in w.topics.keys:
      trace "Keepalive on topic", topic=topic
      let mpeers = w.mesh.getOrDefault(topic)

      w.broadcast(toSeq(mpeers), RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)]))))
    
    await sleepAsync(DefaultKeepAlive)

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

  # after discussions with @sinkingsugar, this is essentially what is needed for
  # the libp2p `StrictNoSign` policy
  w.anonymize = true
  w.verifySignature = false
  w.sign = false

  # Here we can fine-tune GossipSub params for our purposes
  w.parameters = GossipSubParams.init()
  # Setting pruneBackoff allows us to restart nodes and trigger a re-subscribe within reasonable time.
  w.parameters.pruneBackoff = 30.seconds

  procCall GossipSub(w).initPubSub()

  w.init()

method subscribe*(w: WakuRelay,
                  pubSubTopic: string,
                  handler: TopicHandler) =
  debug "subscribe", pubSubTopic=pubSubTopic

  procCall GossipSub(w).subscribe(pubSubTopic, handler)

method publish*(w: WakuRelay,
                pubSubTopic: string,
                message: seq[byte]
               ): Future[int] {.async.} =
  debug "publish", pubSubTopic=pubSubTopic, message=message

  return await procCall GossipSub(w).publish(pubSubTopic, message)

method unsubscribe*(w: WakuRelay,
                    topics: seq[TopicPair]) =
  debug "unsubscribe"

  procCall GossipSub(w).unsubscribe(topics)

method unsubscribeAll*(w: WakuRelay,
                       pubSubTopic: string) =
  debug "unsubscribeAll"

  procCall GossipSub(w).unsubscribeAll(pubSubTopic)

# GossipSub specific methods --------------------------------------------------
method start*(w: WakuRelay) {.async.} =
  debug "start"
  await procCall GossipSub(w).start()
  
  if w.keepAlive:
    # Keep connection to mesh peers alive over periods of idleness
    asyncSpawn keepAlive(w)

method stop*(w: WakuRelay) {.async.} =
  debug "stop"

  w.keepAlive = false

  await procCall GossipSub(w).stop()
