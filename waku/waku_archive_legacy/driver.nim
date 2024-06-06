when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options, stew/results, chronos
import ../waku_core, ./common

const DefaultPageSize*: uint = 25

type
  ArchiveDriverResult*[T] = Result[T, string]
  ArchiveDriver* = ref object of RootObj

#TODO Once Store v2 is removed keep only messages and hashes
type ArchiveRow* = (PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)

# ArchiveDriver interface

method put*(
    driver: ArchiveDriver,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
    digest: MessageDigest,
    messageHash: WakuMessageHash,
    receivedTime: Timestamp,
): Future[ArchiveDriverResult[void]] {.base, async.} =
  discard

method getAllMessages*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.base, async.} =
  discard

method getMessagesV2*(
    driver: ArchiveDriver,
    contentTopic = newSeq[ContentTopic](0),
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.base, deprecated, async.} =
  discard

method getMessages*(
    driver: ArchiveDriver,
    includeData = true,
    contentTopic = newSeq[ContentTopic](0),
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    hashes = newSeq[WakuMessageHash](0),
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.base, async.} =
  discard

method getMessagesCount*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[int64]] {.base, async.} =
  discard

method getPagesCount*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[int64]] {.base, async.} =
  discard

method getPagesSize*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[int64]] {.base, async.} =
  discard

method getDatabaseSize*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[int64]] {.base, async.} =
  discard

method performVacuum*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[void]] {.base, async.} =
  discard

method getOldestMessageTimestamp*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[Timestamp]] {.base, async.} =
  discard

method getNewestMessageTimestamp*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[Timestamp]] {.base, async.} =
  discard

method deleteMessagesOlderThanTimestamp*(
    driver: ArchiveDriver, ts: Timestamp
): Future[ArchiveDriverResult[void]] {.base, async.} =
  discard

method deleteOldestMessagesNotWithinLimit*(
    driver: ArchiveDriver, limit: int
): Future[ArchiveDriverResult[void]] {.base, async.} =
  discard

method decreaseDatabaseSize*(
    driver: ArchiveDriver, targetSizeInBytes: int64, forceRemoval: bool = false
): Future[ArchiveDriverResult[void]] {.base, async.} =
  discard

method close*(
    driver: ArchiveDriver
): Future[ArchiveDriverResult[void]] {.base, async.} =
  discard

method existsTable*(
    driver: ArchiveDriver, tableName: string
): Future[ArchiveDriverResult[bool]] {.base, async.} =
  discard
