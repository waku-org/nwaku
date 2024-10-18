{.push raises: [].}

import std/[options], chronos, libp2p/peerId
import ../waku_core

const
  DefaultSyncInterval*: Duration = 5.minutes
  DefaultSyncRange*: Duration = 1.hours
  RetryDelay*: Duration = 30.seconds
  WakuSyncCodec* = "/vac/waku/sync/1.0.0"
  DefaultMaxFrameSize* = 1048576 # 1 MiB
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
    syncRange*: Option[(uint64, uint64)]

    frameSize*: Option[uint64]

    negentropy*: seq[byte] # negentropy protocol payload

    hashes*: seq[WakuMessageHash]
