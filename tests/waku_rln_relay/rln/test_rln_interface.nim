import testutils/unittests

import waku/waku_rln_relay/rln/rln_interface, ./buffer_utils

suite "Buffer":
  suite "toBuffer":
    test "valid":
      # Given
      let bytes: seq[byte] = @[0x01, 0x02, 0x03]

      # When
      let buffer = bytes.toBuffer()

      # Then
      let expectedBuffer: seq[uint8] = @[1, 2, 3]
      check:
        buffer == expectedBuffer
