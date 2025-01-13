import std/math, results, chronos

import ../../waku_core/time, ../common

type SyncStorage* = ref object of RootObj

method insert*(
    self: SyncStorage, element: ID
): Result[void, string] {.base, gcsafe, raises: [].} =
  discard

method batchInsert*(
    self: SyncStorage, elements: seq[ID]
): Result[void, string] {.base, gcsafe, raises: [].} =
  discard

method prune*(
    self: SyncStorage, timestamp: Timestamp
): int {.base, gcsafe, raises: [].} =
  discard

method fingerprinting*(
    self: SyncStorage, bounds: Slice[ID]
): Fingerprint {.base, gcsafe, raises: [].} =
  discard

method processPayload*(
    self: SyncStorage,
    payload: SyncPayload,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
): SyncPayload {.base, gcsafe, raises: [].} =
  discard

method length*(self: SyncStorage): int {.base, gcsafe, raises: [].} =
  discard
