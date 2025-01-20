import std/math, results, chronos

import ../../waku_core/time, ../common

type SyncStorage* = ref object of RootObj

method insert*(
    self: SyncStorage, element: ID
): Result[void, string] {.base, gcsafe, raises: [].} =
  return err("insert method not implemented for SyncStorage")

method batchInsert*(
    self: SyncStorage, elements: seq[ID]
): Result[void, string] {.base, gcsafe, raises: [].} =
  return err("batchInsert method not implemented for SyncStorage")

method prune*(
    self: SyncStorage, timestamp: Timestamp
): int {.base, gcsafe, raises: [].} =
  -1

method computeFingerprint*(
    self: SyncStorage, bounds: Slice[ID]
): Fingerprint {.base, gcsafe, raises: [].} =
  return EmptyFingerprint

method processPayload*(
    self: SyncStorage,
    payload: SyncPayload,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
): SyncPayload {.base, gcsafe, raises: [].} =
  return SyncPayload()

method length*(self: SyncStorage): int {.base, gcsafe, raises: [].} =
  -1
