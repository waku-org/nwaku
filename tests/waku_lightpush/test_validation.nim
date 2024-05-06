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
      wl = WakuLightPush() # Assuming a constructor or initialization method exists
      pubsubTopic = "testTopic"
      # Create a message that exceeds the default maximum size
      #payload = newSeqWith(DefaultMaxWakuMessageSize + 1, 'a')
      payload = getByteSequence(DefaultMaxWakuMessageSize) # Payload that is too large
      msg = WakuMessage(payload: payload)

    # Call the validateMessage function and check the result
    let result = await wl.validateMessage(pubsubTopic, msg)
    check:
      result.isErr()
      result.error == fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"


# import ./test_client, ./test_ratelimit
#   ../rln/waku_rln_relay_utils

# suite "Message Validation Tests":
#   # setup:
#   #   # Setup required components such as switches and clients if needed

#   # teardown:
#   #   # Teardown any setup components

#   test "Validate message size":
#     # get the current epoch time
#     let time = epochTime()

#     #  create some messages from the same peer and append rln proof to them, except wm4
#     var
#       wm1 = WakuMessage(payload: "Valid message".toBytes())
#       # another message in the same epoch as wm1, it will break the messaging rate limit
#       wm2 = WakuMessage(payload: "Spam".toBytes())
#       #  wm3 points to the next epoch
#       wm3 = WakuMessage(payload: "Valid message".toBytes())
#       wm4 = WakuMessage(payload: "Invalid message".toBytes())

#     wakuRlnRelay.unsafeAppendRLNProof(wm1, time).isOkOr:
#       raiseAssert $error
#     wakuRlnRelay.unsafeAppendRLNProof(wm2, time).isOkOr:
#       raiseAssert $error
#     wakuRlnRelay.unsafeAppendRLNProof(wm3, time + float64(wakuRlnRelay.rlnEpochSizeSec)).isOkOr:
#       raiseAssert $error

#     # validate messages
#     # validateMessage proc checks the validity of the message fields and adds it to the log (if valid)
#     let
#       msgValidate1 = WakuLightPush.validateMessage(wm1, some(time))
#       # wm2 is published within the same Epoch as wm1 and should be found as spam
#       msgValidate2 = WakuLightPush.validateMessage(wm2, some(time))
#       # a valid message should be validated successfully
#       msgValidate3 = WakuLightPush.validateMessage(wm3, some(time))
#       # wm4 has no rln proof and should not be validated
#       msgValidate4 = WakuLightPush.validateMessage(wm4, some(time))

#     check:
#       msgValidate1 == MessageValidationResult.Valid
#       msgValidate2 == MessageValidationResult.Spam
#       msgValidate3 == MessageValidationResult.Valid
#       msgValidate4 == MessageValidationResult.Invalid
