import options, std/[json, strformat]
import chronicles, chronos, results, ffi
import
  ../../../waku/waku_core/message/message,
  ../../../waku/waku_core/codecs,
  ../../../waku/factory/waku,
  ../../../waku/waku_core/message,
  ../../../waku/waku_core/time, # Timestamp
  ../../../waku/waku_core/topics/pubsub_topic,
  ../../../waku/waku_lightpush_legacy/client,
  ../../../waku/waku_lightpush_legacy/common,
  ../../../waku/node/peer_manager/peer_manager,
  ../../events/json_message_event

registerReqFFI(PublishLightpushMsgReq, waku: ptr Waku):
  proc(
      pubSubTopic: cstring, jsonWakuMessage: cstring
  ): Future[Result[string, string]] {.async.} =
    if waku.node.wakuLightpushClient.isNil():
      let errorMsg = "LightpushRequest waku.node.wakuLightpushClient is nil"
      error "PUBLISH failed", error = errorMsg
      return err(errorMsg)

    var jsonMessage: JsonMessage
    try:
      let jsonContent = parseJson($jsonWakuMessage)
      jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
        raise newException(JsonParsingError, $error)
    except JsonParsingError as exc:
      return err(fmt"Error parsing json message: {exc.msg}")

    let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
      return err("Problem building the WakuMessage: " & $error)

    let peerOpt = waku.node.peerManager.selectPeer(WakuLightPushCodec)
    if peerOpt.isNone():
      let errorMsg = "failed to lightpublish message, no suitable remote peers"
      error "PUBLISH failed", error = errorMsg
      return err(errorMsg)

    let msgHashHex = (
      await waku.node.wakuLegacyLightpushClient.publish(
        $pubsubTopic, msg, peer = peerOpt.get()
      )
    ).valueOr:
      error "PUBLISH failed", error = error
      return err($error)

    return ok(msgHashHex)
