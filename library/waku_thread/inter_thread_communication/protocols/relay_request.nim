
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../../waku/v2/node/waku_node,
  ../../../../waku/v2/waku_core/topics/pubsub_topic,
  ../../../../waku/v2/waku_relay/protocol,
  ../request,
  ../response

type
  RelayMsgType* = enum
    SUBSCRIBE
    UNSUBSCRIBE

type
  RelayRequest* = ref object of InterThreadRequest
    operation: RelayMsgType
    pubsubTopic: PubsubTopic
    relayEventCallback: WakuRelayHandler

proc new*(T: type RelayRequest,
          op: RelayMsgType,
          pubsubTopic: PubsubTopic,
          relayEventCallback: WakuRelayHandler): T =

  return RelayRequest(operation: op,
                      pubsubTopic: pubsubTopic,
                      relayEventCallback: relayEventCallback)

method process*(self: RelayRequest,
                node: WakuNode): Future[InterThreadResponse] {.async.} =

  if node.wakuRelay.isNil():
    let msg = "Cannot subscribe or unsubscribe without Waku Relay enabled."
    return InterThreadResponse(result: ResultType.ERROR,
                               message: msg)
  case self.operation:
    of SUBSCRIBE:
      node.wakuRelay.subscribe(self.pubsubTopic,
                               self.relayEventCallback)
    of UNSUBSCRIBE:
      node.wakuRelay.unsubscribe(self.pubsubTopic)

  return InterThreadResponse(result: ResultType.OK)
