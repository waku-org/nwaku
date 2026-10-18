import std/[json, strformat]
import chronicles, chronos, results, ffi
import
  logos_delivery/kernel/[common/message, common/topics/pubsub_topic],
  logos_delivery,
  library/events/json_message_event,
  library/declare_lib
proc waku_lightpush_publish(
    self: LogosDelivery, pubSubTopic: string, jsonWakuMessage: string
): Future[Result[string, string]] {.ffi.} =
  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson(jsonWakuMessage)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
      raise newException(JsonParsingError, $error)
  except JsonParsingError as e:
    return err(fmt"Error parsing json message: {e.msg}")

  let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
    return err("Problem building the WakuMessage: " & $error)

  let msgHashHex = (await self.kernel.lightpushPublish(PubsubTopic(pubSubTopic), msg)).valueOr:
    error "PUBLISH failed", error = error
    return err(error)

  return ok(msgHashHex)
