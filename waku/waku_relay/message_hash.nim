
import
  std/options
import
  stew/[results,byteutils],
  chronicles
import
  ../common/protobuf,
  ../waku_core

import
  stew/results,
  nimcrypto/sha2,
  libp2p/protocols/pubsub,
  libp2p/protocols/pubsub/rpc/messages

proc messageHashProvider*(pubsubTopic: string, messageData: seq[byte]):
                          Result[string, string] {.noSideEffect, raises: [], gcsafe.} =
  ## Given a pubsubtopic and protobuf-encoded message, extracts its WakuMessageHash
  ## representation as an hex string. This proc is used for message tracking
  ## purposes and is aimed to be used within the nim-libp2p library.

  let wakuMsgRes = WakuMessage.decode(messageData)
  if wakuMsgRes.isErr():
    return err("could not decode waku message:" & $wakuMsgRes.error)

  let wakuMsg = wakuMsgRes.get()

  return ok(computeMessageHash(pubsubTopic, wakuMsg).to0xHex())


