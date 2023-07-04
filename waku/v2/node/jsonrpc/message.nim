import
  std/options,
  json,
  json_rpc/rpcserver
import
  ../../../common/base64,
  ../../waku_core


type
  WakuMessageRPC* = object
    payload*: Base64String
    contentTopic*: Option[ContentTopic]
    version*: Option[uint32]
    timestamp*: Option[Timestamp]
    ephemeral*: Option[bool]


## Type mappings

func toWakuMessageRPC*(msg: WakuMessage): WakuMessageRPC =
  WakuMessageRPC(
    payload: base64.encode(msg.payload),
    contentTopic: some(msg.contentTopic),
    version: some(msg.version),
    timestamp: some(msg.timestamp),
    ephemeral: some(msg.ephemeral)
  )


## JSON-RPC type marshalling

# Base64String

proc `%`*(value: Base64String): JsonNode =
  %(value.string)

proc fromJson*(n: JsonNode, argName: string, value: var Base64String) =
  n.kind.expect(JString, argName)

  value = Base64String(n.getStr())

# WakuMessageRpc (WakuMessage)

proc `%`*(value: WakuMessageRpc): JsonNode =
  let jObj = newJObject()
  for k, v in value.fieldPairs:
    jObj[k] = %v
  return jObj
