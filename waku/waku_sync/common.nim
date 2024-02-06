when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options]
import ../waku_core

const WakuSyncCodec* = "/vac/waku/sync/1.0.0"

type SyncPayload* = object
  rangeStart*: Option[uint64]
  rangeEnd*: Option[uint64]

  frameSize*: Option[uint64]

  negentropy*: seq[byte]

  hashes*: seq[WakuMessageHash]
