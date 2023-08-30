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
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/stream/connection,
  libp2p/switch
import
  ../waku_core,
  ./message_id


logScope:
  topics = "waku relay"

const
  WakuRelayCodec* = "/vac/waku/relay/2.0.0"

# see: https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#overview-of-new-parameters
const TopicParameters = TopicParams(
    topicWeight: 1,

    # p1: favours peers already in the mesh
    timeInMeshWeight: 0.01,
    timeInMeshQuantum: 1.seconds,
    timeInMeshCap: 10.0,

    # p2: rewards fast peers
    firstMessageDeliveriesWeight: 1.0,
    firstMessageDeliveriesDecay: 0.5,
    firstMessageDeliveriesCap: 10.0,

    # p3: penalizes lazy peers. safe low value
    meshMessageDeliveriesWeight: 0.0,
    meshMessageDeliveriesDecay: 0.0,
    meshMessageDeliveriesCap: 0,
    meshMessageDeliveriesThreshold: 0,
    meshMessageDeliveriesWindow: 0.milliseconds,
    meshMessageDeliveriesActivation: 0.seconds,

    # p3b: tracks history of prunes
    meshFailurePenaltyWeight: 0.0,
    meshFailurePenaltyDecay: 0.0,

    # p4: penalizes invalid messages. highly penalize
    # peers sending wrong messages
    invalidMessageDeliveriesWeight: -100.0,
    invalidMessageDeliveriesDecay: 0.5
  )

# see: https://rfc.vac.dev/spec/29/#gossipsub-v10-parameters
const GossipsubParameters = GossipSubParams(
    explicit: true,
    pruneBackoff: chronos.minutes(1),
    unsubscribeBackoff: chronos.seconds(5),
    floodPublish: true,
    gossipFactor: 0.25,

    d: 6,
    dLow: 4,
    dHigh: 12,
    dScore: 6,
    dOut: 3,
    dLazy: 6,

    heartbeatInterval: chronos.seconds(1),
    historyLength: 6,
    historyGossip: 3,
    fanoutTTL: chronos.minutes(1),
    seenTTL: chronos.minutes(2),

    # no gossip is sent to peers below this score
    gossipThreshold: -100,

    # no self-published msgs are sent to peers below this score
    publishThreshold: -1000,

    # used to trigger disconnections + ignore peer if below this score
    graylistThreshold: -10000,

    # grafts better peers if the mesh median score drops below this. unset.
    opportunisticGraftThreshold: 0,

    # how often peer scoring is updated
    decayInterval: chronos.seconds(12),

    # below this we consider the parameter to be zero
    decayToZero: 0.01,

    # remember peer score during x after it disconnects
    retainScore: chronos.minutes(10),

    # p5: application specific, unset
    appSpecificWeight: 0.0,

    # p6: penalizes peers sharing more than threshold ips
    ipColocationFactorWeight: -50.0,
    ipColocationFactorThreshold: 5.0,

    # p7: penalizes bad behaviour (weight and decay)
    behaviourPenaltyWeight: -10.0,
    behaviourPenaltyDecay: 0.986,

    # triggers disconnections of bad peers aka score <graylistThreshold
    disconnectBadPeers: true
  )

type
  WakuRelayResult*[T] = Result[T, string]
  WakuRelayHandler* = proc(pubsubTopic: PubsubTopic, message: WakuMessage): Future[void] {.gcsafe, raises: [Defect].}
  WakuRelay* = ref object of GossipSub

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

proc new*(T: type WakuRelay, switch: Switch): WakuRelayResult[T] =

  var w: WakuRelay
  try:
    w = WakuRelay.init(
      switch = switch,
      anonymize = true,
      verifySignature = false,
      sign = false,
      triggerSelf = true,
      msgIdProvider = defaultMessageIdProvider,
      maxMessageSize = MaxWakuMessageSize,
      parameters = GossipsubParameters
    )

    procCall GossipSub(w).initPubSub()
    w.initProtocolHandler()

  except InitializationError:
    return err("initialization error: " & getCurrentExceptionMsg())

  return ok(w)

method addValidator*(w: WakuRelay, topic: varargs[string], handler: ValidatorHandler) {.gcsafe.} =
  procCall GossipSub(w).addValidator(topic, handler)


method start*(w: WakuRelay) {.async.} =
  debug "start"
  await procCall GossipSub(w).start()

method stop*(w: WakuRelay) {.async.} =
  debug "stop"
  await procCall GossipSub(w).stop()

# rejects messages that are not WakuMessage
proc validator(pubsubTopic: string, message: messages.Message): Future[ValidationResult] {.async.} =
  # can be optimized by checking if the message is a WakuMessage without allocating memory
  # see nim-libp2p protobuf library
  let msg = WakuMessage.decode(message.data)
  if msg.isOk():
    return ValidationResult.Accept
  return ValidationResult.Reject

proc isSubscribed*(w: WakuRelay, topic: PubsubTopic): bool =
  GossipSub(w).topics.hasKey(topic)

proc subscribedTopics*(w: WakuRelay): seq[PubsubTopic] =
  return toSeq(GossipSub(w).topics.keys())

proc subscribe*(w: WakuRelay, pubsubTopic: PubsubTopic, handler: WakuRelayHandler) =
  debug "subscribe", pubsubTopic=pubsubTopic

  # we need to wrap the handler since gossipsub doesnt understand WakuMessage
  let wrappedHandler = proc(pubsubTopic: string, data: seq[byte]): Future[void] {.gcsafe, raises: [].} =
    let decMsg = WakuMessage.decode(data)
    if decMsg.isErr():
      # fine if triggerSelf enabled, since validators are bypassed
      error "failed to decode WakuMessage, validator passed a wrong message", error = decMsg.error
      let fut = newFuture[void]()
      fut.complete()
      return fut
    else:
      return handler(pubsubTopic, decMsg.get())

  # add the default validator to the topic
  procCall GossipSub(w).addValidator(pubSubTopic, validator)

  # set this topic parameters for scoring
  w.topicParams[pubsubTopic] = TopicParameters

  # subscribe to the topic with our wrapped handler
  procCall GossipSub(w).subscribe(pubsubTopic, wrappedHandler)

proc unsubscribe*(w: WakuRelay, pubsubTopic: PubsubTopic) =
  debug "unsubscribe", pubsubTopic=pubsubTopic

  procCall GossipSub(w).unsubscribeAll(pubsubTopic)

proc publish*(w: WakuRelay, pubsubTopic: PubsubTopic, message: WakuMessage): Future[int] {.async.} =
  trace "publish", pubsubTopic=pubsubTopic
  let data = message.encode().buffer

  return await procCall GossipSub(w).publish(pubsubTopic, data)
