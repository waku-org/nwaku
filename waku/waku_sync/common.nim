when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options], chronos
import ../waku_core

const
  DefaultSyncInterval*: Duration = 1.hours
  DefaultPruneInterval*: Duration = 30.minutes
  WakuSyncCodec* = "/vac/waku/sync/1.0.0"
  DefaultFrameSize* = 153600
  DefaultGossipSubJitter*: Duration = 20.seconds

type
  SyncCallback* =
    proc(hashes: seq[WakuMessageHash], syncPeer: RemotePeerInfo) {.async: (raises: []).}

  PruneCallback* = proc(
    startTime: Timestamp, endTime: Timestamp, cursor = none(WakuMessageHash)
  ): Future[
    Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
  ] {.async: (raises: []).}

  SyncPayload* = object
    rangeStart*: Option[uint64]
    rangeEnd*: Option[uint64]

    frameSize*: Option[uint64]

    negentropy*: seq[byte] # negentropy protocol payload

    hashes*: seq[WakuMessageHash]
