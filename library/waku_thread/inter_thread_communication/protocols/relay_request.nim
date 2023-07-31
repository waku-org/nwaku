
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../../waku/v2/waku_core/message/message,
  ../../../../waku/v2/node/waku_node,
  ../../../../waku/v2/waku_core/topics/pubsub_topic,
  ../../../../waku/v2/waku_relay/protocol,
  ../request

type
  RelayMsgType* = enum
    SUBSCRIBE
    UNSUBSCRIBE
    PUBLISH

type
  RelayRequest* = ref object of InterThreadRequest
    operation: RelayMsgType
    pubsubTopic: PubsubTopic
    relayEventCallback: WakuRelayHandler # not used in 'PUBLISH' requests
    message: WakuMessage # this field is only used in 'PUBLISH' requests

proc new*(T: type RelayRequest,
          op: RelayMsgType,
          pubsubTopic: PubsubTopic,
          relayEventCallback: WakuRelayHandler = nil,
          message = WakuMessage()): T =

  return RelayRequest(operation: op,
                      pubsubTopic: pubsubTopic,
                      relayEventCallback: relayEventCallback,
                      message: message)

method process*(self: RelayRequest,
                node: WakuNode): Future[Result[string, string]] {.async.} =

  if node.wakuRelay.isNil():
    return err("Operation not supported without Waku Relay enabled.")

  case self.operation:

    of SUBSCRIBE:
      node.wakuRelay.subscribe(self.pubsubTopic, self.relayEventCallback)

    of UNSUBSCRIBE:
      node.wakuRelay.unsubscribe(self.pubsubTopic)

    of PUBLISH:
      let numPeers = await node.wakuRelay.publish(self.pubsubTopic,
                                                  self.message)
      if numPeers == 0:
        return err("Message not sent because no peers found.")

      elif numPeers > 0:
        # TODO: pending to return a valid message Id
        return ok("hard-coded-message-id")

  return ok("")
