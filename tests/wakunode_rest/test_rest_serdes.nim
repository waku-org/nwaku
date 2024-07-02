{.used.}

import stew/[results, byteutils], chronicles, unittest2, json_serialization
import waku/waku_api/rest/serdes, waku/waku_api/rest/debug/types

# TODO: Decouple this test suite from the `debug_api` module by defining
#  private custom types for this test suite module
suite "Waku v2 Rest API - Serdes":
  suite "decode":
    test "decodeFromJsonString - use the corresponding readValue template":
      # Given
      let jsonString = JsonString("""{ "listenAddresses":["123"] }""")

      # When
      let res = decodeFromJsonString(DebugWakuInfo, jsonString, requireAllFields = true)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value.listenAddresses == @["123"]
        value.enrUri.isNone

    test "decodeFromJsonBytes - use the corresponding readValue template":
      # Given
      let jsonBytes = toBytes("""{ "listenAddresses":["123"] }""")

      # When
      let res = decodeFromJsonBytes(DebugWakuInfo, jsonBytes, requireAllFields = true)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value.listenAddresses == @["123"]
        value.enrUri.isNone

  suite "encode":
    test "encodeIntoJsonString - use the corresponding writeValue template":
      # Given
      let data = DebugWakuInfo(listenAddresses: @["GO"])

      # When
      let res = encodeIntoJsonString(data)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value == """{"listenAddresses":["GO"]}"""

    test "encodeIntoJsonBytes - use the corresponding writeValue template":
      # Given
      let data = DebugWakuInfo(listenAddresses: @["ABC"])

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value == toBytes("""{"listenAddresses":["ABC"]}""")
