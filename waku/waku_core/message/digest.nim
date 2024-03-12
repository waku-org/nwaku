when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/sequtils,
  stew/[byteutils, endians2, arrayops],
  nimcrypto/sha2
import
  ../topics,
  ./message


## 14/WAKU2-MESSAGE: Deterministic message hashing
## https://rfc.vac.dev/spec/14/#deterministic-message-hashing

type WakuMessageHash* = array[32, byte]

converter fromBytes*(array: openArray[byte]): WakuMessageHash =
  var hash: WakuMessageHash
  let copiedBytes = copyFrom(hash, array)
  assert copiedBytes == 32, "Waku message hash is 32 bytes"
  hash

converter toBytesArray*(digest: MDigest[256]): WakuMessageHash =
  digest.data

converter toBytes*(digest: MDigest[256]): seq[byte] =
  toSeq(digest.data)

proc computeMessageHash*(pubsubTopic: PubsubTopic, msg: WakuMessage): WakuMessageHash =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(pubsubTopic.toBytes())
  ctx.update(msg.payload)
  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.meta)
  ctx.update(toBytesBE(uint64(msg.timestamp)))

  return ctx.finish()  # Computes the hash
