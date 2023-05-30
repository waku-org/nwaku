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

const topicParams = TopicParams(
    topicWeight: 10.0,  # TODO random number
    timeInMeshWeight: 0.01,
    timeInMeshQuantum: 1.seconds,
    timeInMeshCap: 10.0,
    firstMessageDeliveriesWeight: 1.0,
    firstMessageDeliveriesDecay: 0.5,
    firstMessageDeliveriesCap: 10.0,
    meshMessageDeliveriesWeight: -1.0,
    meshMessageDeliveriesDecay: 0.5,
    meshMessageDeliveriesCap: 10,
    meshMessageDeliveriesThreshold: 1,
    meshMessageDeliveriesWindow: 5.milliseconds,
    meshMessageDeliveriesActivation: 10.seconds,
    meshFailurePenaltyWeight: -1.0,
    meshFailurePenaltyDecay: 0.5,
    invalidMessageDeliveriesWeight: -1.0,
    invalidMessageDeliveriesDecay: 0.5)

const gossipsubParams = GossipSubParams(
    explicit: true,
    pruneBackoff: chronos.minutes(1),
    unsubscribeBackoff: chronos.seconds(10),
    floodPublish: true,
    gossipFactor: 0.05,
    d: 8,
    dLow: 6,
    dHigh: 12,
    dScore: 6,
    dOut: 6 div 2, # less than dlow and no more than dlow/2
    dLazy: 6,
    heartbeatInterval: chronos.milliseconds(700),
    historyLength: 6,
    historyGossip: 3,
    fanoutTTL: chronos.seconds(60),
    seenTTL: chronos.seconds(385),
    gossipThreshold: -4000,
    publishThreshold: -8000,
    graylistThreshold: -16000, # also disconnect threshold
    opportunisticGraftThreshold: 0,
    decayInterval: chronos.seconds(12),
    decayToZero: 0.01,
    retainScore: chronos.seconds(385),
    appSpecificWeight: 0.0,
    ipColocationFactorWeight: -53.75,
    ipColocationFactorThreshold: 3.0,
    behaviourPenaltyWeight: -15.9,
    behaviourPenaltyDecay: 0.986,
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

proc debugPrintRemove(w: WakuRelay) {.async.} =
  while true:
    for k, v in w.peerStats.mpairs:
      echo "---peerStats: peer: ", k, " ", v.score, " ", v.appScore, " ", v.behaviourPenalty
    await sleepAsync(5000)
  #nodes[1].wakuRelay.peerStats[p0Id].topicInfos[spamProtectedTopic].invalidMessageDeliveries == 100.0

proc new*(T: type WakuRelay, switch: Switch, triggerSelf: bool = true): WakuRelayResult[T] =

  var wr: WakuRelay
  try:
    wr = WakuRelay.init(
      switch = switch,
      anonymize = true,
      verifySignature = false,
      sign = false,
      msgIdProvider = defaultMessageIdProvider,
      triggerSelf = triggerSelf,
      maxMessageSize = MaxWakuMessageSize,
      parameters = gossipsubParams
    )

  except InitializationError:
    return err("initialization error: " & getCurrentExceptionMsg())

  asyncSpawn debugPrintRemove(wr)

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

  # rejects messages that are not WakuMessage
  proc validator(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
    let msg = WakuMessage.decode(message.data)
    if msg.isOk():
      # TODO: Unsure if await or asyncSpawn is the closest behaviour
      asyncSpawn handler(pubsubTopic, msg.get)
      return ValidationResult.Accept
    return ValidationResult.Reject

  # add the validator to the topic, that also contains the handler
  w.addValidator(pubSubTopic, validator)

  # set this topic parameters for scoring
  w.topicParams[pubsubTopic] = topicParams

  # nil since we handle it in the validator
  procCall GossipSub(w).subscribe(pubsubTopic, nil)

proc unsubscribe*(w: WakuRelay, topics: PubsubTopic) =
  debug "unsubscribe", pubsubTopic=topics.mapIt(it)

  procCall GossipSub(w).unsubscribe(topics, nil)

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
