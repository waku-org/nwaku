## Waku Relay module. Thin layer on top of GossipSub.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-relay.md
## for spec.
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  stew/results,
  chronos,
  chronicles,
  metrics,
  libp2p/multihash,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/stream/connection,
  libp2p/switch
import
  ../waku_message,
  ./message_id


logScope:
  topics = "waku relay"

const
  WakuRelayCodec* = "/vac/waku/relay/2.0.0"


type WakuRelayResult*[T] = Result[T, string]

type
  PubsubRawHandler* = proc(pubsubTopic: PubsubTopic, data: seq[byte]): Future[void] {.gcsafe, raises: [Defect].}
  SubscriptionHandler* = proc(pubsubTopic: PubsubTopic, message: WakuMessage): Future[void] {.gcsafe, raises: [Defect].}

type
  WakuRelay* = ref object of GossipSub

  WakuRelayHandler* = PubsubRawHandler|SubscriptionHandler


proc initProtocolHandler(w: WakuRelay) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/wakusub/0.0.1``, etc...
    debug "Incoming WakuRelay connection", connection=conn, protocol=proto

    try:
      await w.handleConn(conn, proto)
    except CancelledError:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
      error "Unexpected cancellation in relay handler", conn=conn, error=getCurrentExceptionMsg()
    except CatchableError:
      error "WakuRelay handler leaks an error", conn=conn, error=getCurrentExceptionMsg()

  # XXX: Handler hijack GossipSub here?
  w.handler = handler
  w.codec = WakuRelayCodec

method initPubSub(w: WakuRelay) {.raises: [InitializationError].} =
  ## NOTE: This method overrides GossipSub initPubSub method; it called by the
  ##  parent protocol, PubSub.
  debug "init waku relay"

  # After discussions with @sinkingsugar: This is essentially what is needed for
  # the libp2p `StrictNoSign` policy
  w.anonymize = true
  w.verifySignature = false
  w.sign = false

  procCall GossipSub(w).initPubSub()

  w.initProtocolHandler()


proc new*(T: type WakuRelay, switch: Switch, triggerSelf: bool = true): WakuRelayResult[T] =

  var wr: WakuRelay
  try:
    wr = WakuRelay.init(
      switch = switch,
      msgIdProvider = defaultMessageIdProvider,
      triggerSelf = triggerSelf,
      sign = false,
      verifySignature = false,
      maxMessageSize = MaxWakuMessageSize
    )
  except InitializationError:
    return err("initialization error: " & getCurrentExceptionMsg())

    # TODO: Add a function to validate the WakuMessage integrity
    # # Rejects messages that are not WakuMessage
    # proc validator(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
    #   let msg = WakuMessage.decode(message.data)
    #   if msg.isOk():
    #     return ValidationResult.Accept
    #   return ValidationResult.Reject

    # # Add validator to all default pubsub topics
    # for pubSubTopic in defaultPubsubTopics:
    #   wr.addValidator(pubSubTopic, validator)

  ok(wr)


method addValidator*(w: WakuRelay, topic: varargs[string], handler: ValidatorHandler) {.gcsafe.} =
  procCall GossipSub(w).addValidator(topic, handler)


method start*(w: WakuRelay) {.async.} =
  debug "start"
  await procCall GossipSub(w).start()

method stop*(w: WakuRelay) {.async.} =
  debug "stop"
  await procCall GossipSub(w).stop()


proc isSubscribed*(w: WakuRelay, topic: PubsubTopic): bool =
  GossipSub(w).topics.hasKey(topic)

iterator subscribedTopics*(w: WakuRelay): lent PubsubTopic =
  for topic in GossipSub(w).topics.keys():
    yield topic

proc subscribe*(w: WakuRelay, pubsubTopic: PubsubTopic, handler: WakuRelayHandler) =
  debug "subscribe", pubsubTopic=pubsubTopic

  var subsHandler: PubsubRawHandler
  when handler is SubscriptionHandler:
    subsHandler = proc(pubsubTopic: PubsubTopic, data: seq[byte]): Future[void] {.gcsafe.} =
        let decodeRes = WakuMessage.decode(data)
        if decodeRes.isErr():
          debug "message decode failure", pubsubTopic=pubsubTopic, error=decodeRes.error
          return

        handler(pubsubTopic, decodeRes.value)
  else:
    subsHandler = handler

  procCall GossipSub(w).subscribe(pubsubTopic, subsHandler)

proc unsubscribe*(w: WakuRelay, topics: seq[TopicPair]) =
  debug "unsubscribe", pubsubTopic=topics.mapIt(it[0])

  procCall GossipSub(w).unsubscribe(topics)

proc unsubscribeAll*(w: WakuRelay, pubsubTopic: PubsubTopic) =
  debug "unsubscribeAll", pubsubTopic=pubsubTopic

  procCall GossipSub(w).unsubscribeAll(pubsubTopic)


proc publish*(w: WakuRelay, pubsubTopic: PubsubTopic, message: WakuMessage|seq[byte]): Future[int] {.async.} =
  trace "publish", pubsubTopic=pubsubTopic

  var data: seq[byte]
  when message is WakuMessage:
    data = message.encode().buffer
  else:
    data = message

  return await procCall GossipSub(w).publish(pubsubTopic, data)
