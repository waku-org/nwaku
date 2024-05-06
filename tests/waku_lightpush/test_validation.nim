{.used.}

import
  ../../../waku/waku_core,
  ../../../waku/waku_lightpush/protocol,
  testutils/unittests,
  ../resources/payloads,
  std/strformat,
  chronos,
  sequtils,
  stew/results

suite "WakuLightPush Protocol Tests":
  asyncTest "Validate message size exceeds limit":
    let
      wl = WakuLightPush()
      pubsubTopic = "testTopic"
      # Create a message that exceeds the default maximum size
      payload = getByteSequence(DefaultMaxWakuMessageSize)
      msg = WakuMessage(payload: payload)

    # Call the validateMessage function and check the result
    let result = await wl.validateMessage(pubsubTopic, msg)
    check:
      result.isErr()
      result.error == fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"