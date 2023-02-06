when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  eth/keys
import
  ../../../../waku/v2/protocol/waku_message,
  ../../../../waku/v2/utils/time

type
  WakuRelayMessage* = object
    payload*: seq[byte]
    contentTopic*: Option[ContentTopic]
    timestamp*: Option[Timestamp]

  WakuKeyPair* = object
    seckey*: keys.PrivateKey
    pubkey*: keys.PublicKey

