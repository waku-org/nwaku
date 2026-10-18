{.push raises: [].}

import std/sequtils, stew/[byteutils, endians2]
import logos_delivery/kernel/[base/message]
proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## The signal an RLN proof is bound to: the message's payload, content topic
  ## and timestamp, serialized into one byte sequence.
  let
    contentTopicBytes = toBytes(wakumessage.contentTopic)
    timestampBytes = toBytes(wakumessage.timestamp.uint64)
    output = concat(wakumessage.payload, contentTopicBytes, @(timestampBytes))
  return output

{.pop.}
