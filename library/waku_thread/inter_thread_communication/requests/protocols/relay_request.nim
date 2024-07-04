import std/net
import chronicles, chronos, stew/byteutils, results
import
  ../../../../../waku/waku_core/message/message,
  ../../../../../waku/factory/waku,
  ../../../../../waku/waku_core/message,
  ../../../../../waku/waku_core/time, # Timestamp
  ../../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../../waku/waku_relay/protocol,
  ../../../../alloc

type RelayMsgType* = enum
  SUBSCRIBE
  UNSUBSCRIBE
  PUBLISH

type ThreadSafeWakuMessage* = object
  payload: SharedSeq[byte]
  contentTopic: cstring
  meta: SharedSeq[byte]
  version: uint32
  timestamp: Timestamp
  ephemeral: bool
  when defined(rln):
    proof: SharedSeq[byte]

type RelayRequest* = object
  operation: RelayMsgType
  pubsubTopic: cstring
  relayEventCallback: WakuRelayHandler # not used in 'PUBLISH' requests
  message: ThreadSafeWakuMessage # only used in 'PUBLISH' requests

proc createShared*(
    T: type RelayRequest,
    op: RelayMsgType,
    pubsubTopic: PubsubTopic,
    relayEventCallback: WakuRelayHandler = nil,
    m = WakuMessage(),
): ptr type T =
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

proc process*(
    self: ptr RelayRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  if waku.node.wakuRelay.isNil():
    return err("Operation not supported without Waku Relay enabled.")

  case self.operation
  of SUBSCRIBE:
    # TO DO: properly perform 'subscribe'
    discard waku.node.wakuRelay.subscribe($self.pubsubTopic, self.relayEventCallback)
  of UNSUBSCRIBE:
    # TODO: properly perform 'unsubscribe'
    waku.node.wakuRelay.unsubscribeAll($self.pubsubTopic)
  of PUBLISH:
    let msg = self.message.toWakuMessage()
    let pubsubTopic = $self.pubsubTopic

    let numPeers = await waku.node.wakuRelay.publish(pubsubTopic, msg)
    if numPeers == 0:
      return err("Message not sent because no peers found.")
    elif numPeers > 0:
      let msgHash = computeMessageHash(pubSubTopic, msg).to0xHex
      return ok(msgHash)

  return ok("")
