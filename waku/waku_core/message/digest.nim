when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/sequtils,
  stew/byteutils,
  stew/endians2,
  nimcrypto/sha2,
  chronicles
import
  ../topics,
  ./message,
  ./codec,
  ../../common/protobuf


## 14/WAKU2-MESSAGE: Deterministic message hashing
## https://rfc.vac.dev/spec/14/#deterministic-message-hashing

type WakuMessageHash* = array[32, byte]


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

