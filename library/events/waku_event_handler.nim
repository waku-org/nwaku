import chronos, chronicles
import
  waku/node/peer_manager,
  waku/waku_relay,
  waku/waku_core/message/message,
  waku/waku_core/topics/pubsub_topic,
  ../waku_context/waku_context,
  ../ffi_types,
  ./[
    json_message_event, json_topic_health_change_event, json_connection_change_event,
    json_waku_not_responding_event,
  ]

template callEventCallback(ctx: ptr WakuContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[WakuCallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[WakuCallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

proc onConnectionChange*(ctx: ptr WakuContext): ConnectionChangeHandler =
  return proc(peerId: PeerId, peerEvent: PeerEventKind) {.async.} =
    callEventCallback(ctx, "onConnectionChange"):
      $JsonConnectionChangeEvent.new($peerId, peerEvent)

proc onReceivedMessage*(ctx: ptr WakuContext): WakuRelayHandler =
  return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
    callEventCallback(ctx, "onReceivedMessage"):
      $JsonMessageEvent.new(pubsubTopic, msg)

proc onTopicHealthChange*(ctx: ptr WakuContext): TopicHealthChangeHandler =
  return proc(pubsubTopic: PubsubTopic, topicHealth: TopicHealth) {.async.} =
    callEventCallback(ctx, "onTopicHealthChange"):
      $JsonTopicHealthChangeEvent.new(pubsubTopic, topicHealth)

type WakuNotRespondingHandler = proc() {.async.}

proc onWakuNotResponsive*(ctx: ptr WakuContext): WakuNotRespondingHandler =
  return proc() {.async.} =
    callEventCallback(ctx, "onWakuNotResponsive"):
      $JsonWakuNotRespondingEvent.new()
