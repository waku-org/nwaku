when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options], chronos, libp2p/peerId
import ../waku_core

const
  DefaultSyncInterval*: Duration = 1.hours
  WakuSyncCodec* = "/vac/waku/sync/1.0.0"
  DefaultMaxFrameSize* = 153600 #TODO change to something sensible
  DefaultGossipSubJitter*: Duration = 20.seconds

type
  TransferCallback* = proc(
    hashes: seq[WakuMessageHash], peerId: PeerId
  ): Future[Result[void, string]] {.async: (raises: []), closure.}

  PruneCallback* = proc(
    startTime: Timestamp, endTime: Timestamp, cursor = none(WakuMessageHash)
  ): Future[
    Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
  ] {.async: (raises: []), closure.}

  SyncPayload* = object
    rangeStart*: Option[uint64]
    rangeEnd*: Option[uint64]

    frameSize*: Option[uint64]

    negentropy*: seq[byte] # negentropy protocol payload

    hashes*: seq[WakuMessageHash]
