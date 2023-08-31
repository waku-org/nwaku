
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../../../waku/waku_core/message/message,
  ../../../../../waku/node/waku_node,
  ../../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../../waku/waku_relay/protocol

type
  RelayMsgType* = enum
    SUBSCRIBE
    UNSUBSCRIBE
    PUBLISH

type
  RelayRequest* = object
    operation: RelayMsgType
    pubsubTopic: PubsubTopic
    relayEventCallback: WakuRelayHandler # not used in 'PUBLISH' requests
    message: WakuMessage # this field is only used in 'PUBLISH' requests

proc new*(T: type RelayRequest,
          op: RelayMsgType,
          pubsubTopic: PubsubTopic,
          relayEventCallback: WakuRelayHandler = nil,
          message = WakuMessage()): ptr RelayRequest =

  var ret = cast[ptr RelayRequest](allocShared0(sizeof(RelayRequest)))
  ret[].operation = op
  ret[].pubsubTopic = pubsubTopic
  ret[].relayEventCallback = relayEventCallback
  ret[].message = message
  return ret

proc process*(self: ptr RelayRequest,
              node: ptr WakuNode): Future[Result[string, string]] {.async.} =

  defer: deallocShared(self)

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
