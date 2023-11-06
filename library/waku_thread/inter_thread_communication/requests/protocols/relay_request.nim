
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
  ../../../../../waku/waku_core/time, # Timestamp
  ../../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../../waku/waku_relay/protocol,
  ../../../../alloc

type
  RelayMsgType* = enum
    SUBSCRIBE
    UNSUBSCRIBE
    PUBLISH

type
  ThreadSafeWakuMessage* = object
    payload: SharedSeq[byte]
    contentTopic: cstring
    meta: SharedSeq[byte]
    version: uint32
    timestamp: Timestamp
    ephemeral: bool
    when defined(rln):
      proof: SharedSeq[byte]

type
  RelayRequest* = object
    operation: RelayMsgType
    pubsubTopic: cstring
    relayEventCallback: WakuRelayHandler # not used in 'PUBLISH' requests
    message: ThreadSafeWakuMessage # only used in 'PUBLISH' requests

proc createShared*(T: type RelayRequest,
                   op: RelayMsgType,
                   pubsubTopic: PubsubTopic,
                   relayEventCallback: WakuRelayHandler = nil,
                   m = WakuMessage()): ptr type T =

  var ret = createShared(T)
  ret[].operation = op
  ret[].pubsubTopic = pubsubTopic.alloc()
  ret[].relayEventCallback = relayEventCallback
  ret[].message = ThreadSafeWakuMessage(
                                payload: allocSharedSeq(m.payload),
                                contentTopic: m.contentTopic.alloc(),
                                meta: allocSharedSeq(m.meta),
                                version: m.version,
                                timestamp: m.timestamp,
                                ephemeral: m.ephemeral,
                            )
  when defined(rln):
    ret[].message.proof = allocSharedSeq(m.proof)

  return ret

proc destroyShared(self: ptr RelayRequest) =
  deallocSharedSeq(self[].message.payload)
  deallocShared(self[].message.contentTopic)
  deallocSharedSeq(self[].message.meta)
  when defined(rln):
    deallocSharedSeq(self[].message.proof)

  deallocShared(self)

proc toWakuMessage(m: ThreadSafeWakuMessage): WakuMessage =
  var wakuMessage = WakuMessage()

  wakuMessage.payload = m.payload.toSeq()
  wakuMessage.contentTopic = $m.contentTopic
  wakuMessage.meta = m.meta.toSeq()
  wakuMessage.version = m.version
  wakuMessage.timestamp = m.timestamp
  wakuMessage.ephemeral = m.ephemeral

  when defined(rln):
    wakuMessage.proof = m.proof

  return wakuMessage

proc process*(self: ptr RelayRequest,
              node: ptr WakuNode): Future[Result[string, string]] {.async.} =

  defer: destroyShared(self)

  if node.wakuRelay.isNil():
    return err("Operation not supported without Waku Relay enabled.")

  case self.operation:

    of SUBSCRIBE:
      # TO DO: properly perform 'subscribe'
      discard node.wakuRelay.subscribe($self.pubsubTopic, self.relayEventCallback)

    of UNSUBSCRIBE:
      # TODO: properly perform 'unsubscribe'
      node.wakuRelay.unsubscribeAll($self.pubsubTopic)

    of PUBLISH:
      let numPeers = await node.wakuRelay.publish($self.pubsubTopic,
                                                  self.message.toWakuMessage())
      if numPeers == 0:
        return err("Message not sent because no peers found.")

      elif numPeers > 0:
        # TODO: pending to return a valid message Id
        return ok("hard-coded-message-id")

  return ok("")
