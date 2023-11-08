{.used.}

import
  std/sequtils,
  stew/byteutils,
  testutils/unittests
import
  ../../../waku/waku_core,
  ../testlib/wakucore

suite "Waku Message - Deterministic hashing":

  test "digest computation - empty meta field":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = 0x010203045445535405060708
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = <empty>
    ##
    ##  message_hash = 0x87619d05e563521d9126749b45bd4cc2430df0607e77e23572d874ed9c1aaa62

    ## Given
    let pubsubTopic = DefaultPubsubTopic  # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
        contentTopic = DefaultContentTopic,  # /waku/2/default-content/proto
        payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
        meta = newSeq[byte]()
      )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      byteutils.toHex(pubsubTopic.toBytes()) == "2f77616b752f322f64656661756c742d77616b752f70726f746f"
      byteutils.toHex(message.contentTopic.toBytes()) == "2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f"
      byteutils.toHex(message.payload) == "010203045445535405060708"
      byteutils.toHex(message.meta) == ""
      messageHash.toHex() == "87619d05e563521d9126749b45bd4cc2430df0607e77e23572d874ed9c1aaa62"

  test "digest computation - meta field (12 bytes)":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = 0x010203045445535405060708
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = 0x73757065722d736563726574
    ##
    ##  message_hash = 0x4fdde1099c9f77f6dae8147b6b3179aba1fc8e14a7bf35203fc253ee479f135f

    ## Given
    let pubsubTopic = DefaultPubsubTopic  # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
        contentTopic = DefaultContentTopic,  # /waku/2/default-content/proto
        payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
        meta = "\x73\x75\x70\x65\x72\x2d\x73\x65\x63\x72\x65\x74".toBytes()
      )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      byteutils.toHex(pubsubTopic.toBytes()) == "2f77616b752f322f64656661756c742d77616b752f70726f746f"
      byteutils.toHex(message.contentTopic.toBytes()) == "2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f"
      byteutils.toHex(message.payload) == "010203045445535405060708"
      byteutils.toHex(message.meta) == "73757065722d736563726574"
      messageHash.toHex() == "4fdde1099c9f77f6dae8147b6b3179aba1fc8e14a7bf35203fc253ee479f135f"

  test "digest computation - meta field (64 bytes)":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = 0x010203045445535405060708
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = 0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
    ##
    ##  message_hash = 0xc32ed3b51f0c432be1c7f50880110e1a1a60f6067cd8193ca946909efe1b26ad

    ## Given
    let pubsubTopic = DefaultPubsubTopic  # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic,  # /waku/2/default-content/proto
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = toSeq(0.byte..63.byte)
    )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      byteutils.toHex(pubsubTopic.toBytes()) == "2f77616b752f322f64656661756c742d77616b752f70726f746f"
      byteutils.toHex(message.contentTopic.toBytes()) == "2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f"
      byteutils.toHex(message.payload) == "010203045445535405060708"
      byteutils.toHex(message.meta) == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
      messageHash.toHex() == "c32ed3b51f0c432be1c7f50880110e1a1a60f6067cd8193ca946909efe1b26ad"

  test "digest computation - zero length payload":
    ## Test vector:
    ##
    ##  pubsub_topic = 0x2f77616b752f322f64656661756c742d77616b752f70726f746f
    ##  waku_message.payload = []
    ##  waku_message.content_topic = 0x2f77616b752f322f64656661756c742d636f6e74656e742f70726f746f
    ##  waku_message.meta = 0x73757065722d736563726574
    ##
    ##  message_hash = 0xe1a9596237dbe2cc8aaf4b838c46a7052df6bc0d42ba214b998a8bfdbe8487d6

    ## Given
    let pubsubTopic = DefaultPubsubTopic  # /waku/2/default-waku/proto
    let message = fakeWakuMessage(
        contentTopic = DefaultContentTopic,  # /waku/2/default-content/proto
        payload = newSeq[byte](),
        meta = "\x73\x75\x70\x65\x72\x2d\x73\x65\x63\x72\x65\x74".toBytes()
      )

    ## When
    let messageHash = computeMessageHash(pubsubTopic, message)

    ## Then
    check:
      messageHash.toHex() == "e1a9596237dbe2cc8aaf4b838c46a7052df6bc0d42ba214b998a8bfdbe8487d6"

  test "waku message - check meta size is enforced":
    # create message with meta size > 64 bytes (invalid)
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic,
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = toSeq(0.byte..66.byte) # 67 bytes
    )

    let encodedInvalidMsg = message.encode
    let decoded = WakuMessage.decode(encodedInvalidMsg.buffer)

    check:
      decoded.isErr == true
      $decoded.error == "(kind: InvalidLengthField, field: \"meta\")"
