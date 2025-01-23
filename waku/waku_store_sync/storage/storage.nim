import results

import ../../waku_core/time, ../common

type SyncStorage* = ref object of RootObj

method insert*(
    self: SyncStorage, element: SyncID
): Result[void, string] {.base, gcsafe, raises: [].} =
  return err("insert method not implemented for SyncStorage")

method batchInsert*(
    self: SyncStorage, elements: seq[SyncID]
): Result[void, string] {.base, gcsafe, raises: [].} =
  return err("batchInsert method not implemented for SyncStorage")

method prune*(
    self: SyncStorage, timestamp: Timestamp
): int {.base, gcsafe, raises: [].} =
  -1

method computeFingerprint*(
    self: SyncStorage, bounds: Slice[SyncID]
): Fingerprint {.base, gcsafe, raises: [].} =
  return EmptyFingerprint

method processPayload*(
    self: SyncStorage,
    payload: RangesData,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
): RangesData {.base, gcsafe, raises: [].} =
  return RangesData()

method length*(self: SyncStorage): int {.base, gcsafe, raises: [].} =
  -1
