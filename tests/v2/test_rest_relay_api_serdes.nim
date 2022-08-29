{.used.}

import
  stew/[results, byteutils],
  chronicles,
  unittest2,
  json_serialization
import 
  ../../waku/v2/node/rest/serdes,
  ../../waku/v2/node/rest/base64,
  ../../waku/v2/node/rest/relay/api_types


suite "Relay API - serialization":

  suite "RelayWakuMessage - decode":
    test "optional fields are not provided":
      # Given
      let payload = Base64String.encode("MESSAGE")
      let jsonBytes = toBytes("{\"payload\":\"" & $payload & "\"}")

      # When
      let res = decodeFromJsonBytes(RelayWakuMessage, jsonBytes, requireAllFields = true)

      # Then
      require(res.isOk())
      let value = res.get()
      check:
        value.payload == payload
        value.contentTopic.isNone()
        value.version.isNone()
        value.timestamp.isNone()

  suite "RelayWakuMessage - encode":
    test "optional fields are none":
      # Given
      let payload = Base64String.encode("MESSAGE")
      let data = RelayWakuMessage(
        payload: payload, 
        contentTopic: none(ContentTopicString),
        version: none(Natural),
        timestamp: none(int64)
      )

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk())
      let value = res.get()
      check:
        value == toBytes("{\"payload\":\"" & $payload & "\"}")
