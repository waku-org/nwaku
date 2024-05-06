when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options], chronos
import ../waku_core

const DefaultSyncInterval*: timer.Duration = Hour
const WakuSyncCodec* = "/vac/waku/sync/1.0.0"
const DefaultFrameSize* = 153600

type WakuSyncCallback* = proc(hashes: seq[WakuMessageHash], syncPeer: RemotePeerInfo) {.
  async: (raises: []), closure
.}

type SyncPayload* = object
  rangeStart*: Option[uint64]
  rangeEnd*: Option[uint64]

  frameSize*: Option[uint64]

  negentropy*: seq[byte] # negentropy protocol payload

  hashes*: seq[WakuMessageHash]
