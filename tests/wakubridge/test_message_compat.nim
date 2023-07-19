
{.used.}

import
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/switch
import
  ../../waku/v2/waku_core

import
  ../../apps/wakubridge/message_compat


suite "WakuBridge - Message compat":

  test "Topics are correctly converted between Waku v1 and Waku v2":
    # Expected cases

    check:
      toV1Topic(ContentTopic("/0/none/waku/1/0x00000000/rfc26")) == [byte 0x00, byte 0x00, byte 0x00, byte 0x00]
      toV2ContentTopic([byte 0x00, byte 0x00, byte 0x00, byte 0x00]) == ContentTopic("/0/none/waku/1/0x00000000/rfc26")
      toV1Topic(ContentTopic("/0/none/waku/1/0xffffffff/rfc26")) == [byte 0xff, byte 0xff, byte 0xff, byte 0xff]
      toV2ContentTopic([byte 0xff, byte 0xff, byte 0xff, byte 0xff]) == ContentTopic("/0/none/waku/1/0xffffffff/rfc26")
      toV1Topic(ContentTopic("/0/none/waku/1/0x1a2b3c4d/rfc26")) == [byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]
      toV2ContentTopic([byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]) == ContentTopic("/0/none/waku/1/0x1a2b3c4d/rfc26")
      # Topic conversion should still work where '0x' prefix is omitted from <v1 topic byte array>
      toV1Topic(ContentTopic("/0/none/waku/1/1a2b3c4d/rfc26")) == [byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]

    # Invalid cases

  test "Invalid topics conversion between Waku v1 and Waku v2 fails":
    expect ValueError:
      # Content topic not namespaced
      discard toV1Topic(ContentTopic("this-is-my-content"))

    expect ValueError:
      # Content topic name too short
      discard toV1Topic(ContentTopic("/0/none/waku/1/0x112233/rfc26"))

    expect ValueError:
      # Content topic name not hex
      discard toV1Topic(ContentTopic("/0/none/waku/1/my-content/rfc26"))

  test "Verify that WakuMessages are on bridgeable content topics":
    let
      validCT = ContentTopic("/0/none/waku/1/my-content/rfc26")
      unnamespacedCT = ContentTopic("just_a_bunch_of_words")
      invalidAppCT = ContentTopic("/0/none/facebook/1/my-content/rfc26")
      invalidVersionCT = ContentTopic("/0/none/waku/2/my-content/rfc26")

    check:
      WakuMessage(contentTopic: validCT).isBridgeable() == true
      WakuMessage(contentTopic: unnamespacedCT).isBridgeable() == false
      WakuMessage(contentTopic: invalidAppCT).isBridgeable() == false
      WakuMessage(contentTopic: invalidVersionCT).isBridgeable() == false

