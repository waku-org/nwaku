{.used.}

import std/sequtils, stew/byteutils, stew/endians2, testutils/unittests
import waku/waku_core, ../testlib/wakucore

suite "Waku Message - Deterministic hashing":
  test "digest computation - empty meta field":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = 0x010203045445535405060708
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = <empty>
    ##  waku_message.ts = 0x175789bfa23f8400
    ##
    ##  message_hash = 0xa2554498b31f5bcdfcbf7fa58ad1c2d45f0254f3f8110a85588ec3cf10720fd8

    ## Given
    let pubsubTopic = DefaultPubsubTopic # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic, # /waku/2/default-content/proto
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = newSeq[byte](),
      ts = getNanosecondTime(1681964442), # Apr 20 2023 04:20:42
    )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      byteutils.toHex(pubsubTopic.toBytes()) ==
        "2f77616b752f322f64656661756c742d77616b752f70726f746f"
      byteutils.toHex(message.contentTopic.toBytes()) ==
        "2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f"
      byteutils.toHex(message.payload) == "010203045445535405060708"
      byteutils.toHex(message.meta) == ""
      byteutils.toHex(toBytesBE(uint64(message.timestamp))) == "175789bfa23f8400"
      messageHash.toHex() ==
        "a2554498b31f5bcdfcbf7fa58ad1c2d45f0254f3f8110a85588ec3cf10720fd8"

  test "digest computation - meta field (12 bytes)":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = 0x010203045445535405060708
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = 0x73757065722d736563726574
    ##  waku_message.ts = 0x175789bfa23f8400
    ##
    ##  message_hash = 0x64cce733fed134e83da02b02c6f689814872b1a0ac97ea56b76095c3c72bfe05

    ## Given
    let pubsubTopic = DefaultPubsubTopic # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic, # /waku/2/default-content/proto
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = "\x73\x75\x70\x65\x72\x2d\x73\x65\x63\x72\x65\x74".toBytes(),
      ts = getNanosecondTime(1681964442), # Apr 20 2023 04:20:42
    )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      byteutils.toHex(pubsubTopic.toBytes()) ==
        "2f77616b752f322f64656661756c742d77616b752f70726f746f"
      byteutils.toHex(message.contentTopic.toBytes()) ==
        "2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f"
      byteutils.toHex(message.payload) == "010203045445535405060708"
      byteutils.toHex(message.meta) == "73757065722d736563726574"
      byteutils.toHex(toBytesBE(uint64(message.timestamp))) == "175789bfa23f8400"
      messageHash.toHex() ==
        "64cce733fed134e83da02b02c6f689814872b1a0ac97ea56b76095c3c72bfe05"

  test "digest computation - meta field (64 bytes)":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = 0x010203045445535405060708
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = 0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
    ##  waku_message.ts = 0x175789bfa23f8400
    ##
    ##  message_hash = 0x7158b6498753313368b9af8f6e0a0a05104f68f972981da42a43bc53fb0c1b27"

    ## Given
    let pubsubTopic = DefaultPubsubTopic # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic, # /waku/2/default-content/proto
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = toSeq(0.byte .. 63.byte),
      ts = getNanosecondTime(1681964442), # Apr 20 2023 04:20:42
    )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      byteutils.toHex(pubsubTopic.toBytes()) ==
        "2f77616b752f322f64656661756c742d77616b752f70726f746f"
      byteutils.toHex(message.contentTopic.toBytes()) ==
        "2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f"
      byteutils.toHex(message.payload) == "010203045445535405060708"
      byteutils.toHex(message.meta) ==
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
      byteutils.toHex(toBytesBE(uint64(message.timestamp))) == "175789bfa23f8400"
      messageHash.toHex() ==
        "7158b6498753313368b9af8f6e0a0a05104f68f972981da42a43bc53fb0c1b27"

  test "digest computation - zero length payload":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = []
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = 0x73757065722d736563726574
    ##  waku_message.ts = 0x175789bfa23f8400
    ##
    ##  message_hash = 0x483ea950cb63f9b9d6926b262bb36194d3f40a0463ce8446228350bd44e96de4

    ## Given
    let pubsubTopic = DefaultPubsubTopic # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic, # /waku/2/default-content/proto
      payload = newSeq[byte](),
      meta = "\x73\x75\x70\x65\x72\x2d\x73\x65\x63\x72\x65\x74".toBytes(),
      ts = getNanosecondTime(1681964442), # Apr 20 2023 04:20:42
    )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      messageHash.toHex() ==
        "483ea950cb63f9b9d6926b262bb36194d3f40a0463ce8446228350bd44e96de4"

  test "waku message - check meta size is enforced":
    # create message with meta size > 64 bytes (invalid)
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic,
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = toSeq(0.byte .. 66.byte), # 67 bytes
    )

    let encodedInvalidMsg = message.encode
    let decoded = WakuMessage.decode(encodedInvalidMsg.buffer)

    check:
      decoded.isErr == true
      $decoded.error == "(kind: InvalidLengthField, field: \"meta\")"
