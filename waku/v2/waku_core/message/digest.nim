when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/sequtils,
  stew/byteutils,
  nimcrypto/sha2
import
  ../topics,
  ./message


## 14/WAKU2-MESSAGE: Deterministic message hashing
## https://rfc.vac.dev/spec/14/#deterministic-message-hashing

type WakuMessageDigest* = array[32, byte]


converter toBytesArray*(digest: MDigest[256]): WakuMessageDigest =
  digest.data

converter toBytes*(digest: MDigest[256]): seq[byte] =
  toSeq(digest.data)


proc digest*(pubsubTopic: PubsubTopic, msg: WakuMessage): WakuMessageDigest =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(pubsubTopic.toBytes())
  ctx.update(msg.payload)
  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.meta)

  return ctx.finish()  # Computes the hash
