{.used.}

import std/typetraits
import chronicles,
  unittest2,
  stew/[results, byteutils],
  json_serialization
import 
  ../../waku/v2/node/rest/serdes,
  ../../waku/v2/node/rest/relay/api_types


suite "Relay API - serialization":

  suite "RelayWakuMessage - decode":
    test "optional fields are not provided":
      # Given
      let jsonBytes = toBytes("""{ "payload": "MESSAGE" }""")

      # When
      let res = decodeFromJsonBytes(RelayWakuMessage, jsonBytes, requireAllFields = true)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value.payload == "MESSAGE"
        value.contentTopic.isNone
        value.version.isNone
        value.timestamp.isNone

  suite "RelayWakuMessage - encode":
    test "optional fields are none":
      # Given
      let data = RelayWakuMessage(
        payload: "MESSAGE", 
        contentTopic: none(ContentTopicString),
        version: none(Natural),
        timestamp: none(int64)
      )

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value == toBytes("""{"payload":"MESSAGE"}""")
