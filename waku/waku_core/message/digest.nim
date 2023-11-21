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

converter toBytesFromInt64*(num: int64): seq[byte] =
  var bytes: seq[byte] = newSeq[byte](8)  # Create a sequence for 8 bytes (int64)

  # Extract and store each byte uinsg Big-endian method
  for i in 0..<8:
      bytes[i] = byte((num shr (56 - i * 8)) and 0xFF)

  return bytes

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
  ctx.update((msg.timestamp).toBytesFromInt64())

  return ctx.finish()  # Computes the hash
