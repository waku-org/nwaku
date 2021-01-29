## Waku Relay module. Thin layer on top of GossipSub.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-relay.md
## for spec.

import
  chronos, chronicles, metrics,
  libp2p/protocols/pubsub/[pubsub, gossipsub],
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/stream/connection

logScope:
    topics = "wakurelay"

const WakuRelayCodec* = "/vac/waku/relay/2.0.0-beta2"

type
  WakuRelay* = ref object of GossipSub

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

  procCall GossipSub(w).initPubSub()

  w.init()

method subscribe*(w: WakuRelay,
                  pubSubTopic: string,
                  handler: TopicHandler) {.async.} =
  debug "subscribe", pubSubTopic=pubSubTopic

  await procCall GossipSub(w).subscribe(pubSubTopic, handler)

method publish*(w: WakuRelay,
                pubSubTopic: string,
                message: seq[byte]
               ): Future[int] {.async.} =
  debug "publish", pubSubTopic=pubSubTopic, message=message

  return await procCall GossipSub(w).publish(pubSubTopic, message)

method unsubscribe*(w: WakuRelay,
                    topics: seq[TopicPair]) {.async.} =
  debug "unsubscribe"

  await procCall GossipSub(w).unsubscribe(topics)

method unsubscribeAll*(w: WakuRelay,
                       pubSubTopic: string) {.async.} =
  debug "unsubscribeAll"

  await procCall GossipSub(w).unsubscribeAll(pubSubTopic)

# GossipSub specific methods --------------------------------------------------
method start*(w: WakuRelay) {.async.} =
  debug "start"
  await procCall GossipSub(w).start()

method stop*(w: WakuRelay) {.async.} =
  debug "stop"
  await procCall GossipSub(w).stop()
