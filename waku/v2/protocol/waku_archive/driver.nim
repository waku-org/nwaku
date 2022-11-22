when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results
import
  ../../utils/time,
  ../waku_message,
  ./common


const DefaultPageSize*: uint = 25


type
  ArchiveDriverResult*[T] = Result[T, string]

  ArchiveDriver* = ref object of RootObj

type ArchiveRow* = (PubsubTopic, WakuMessage, seq[byte], Timestamp)


# ArchiveDriver interface

method put*(driver: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage, digest: MessageDigest, receivedTime: Timestamp): ArchiveDriverResult[void] {.base.} = discard


method getAllMessages*(driver: ArchiveDriver): ArchiveDriverResult[seq[ArchiveRow]] {.base.} = discard

method getMessages*(
  driver: ArchiveDriver,
  contentTopic: seq[ContentTopic] = @[],
  pubsubTopic = none(PubsubTopic),
  cursor = none(ArchiveCursor),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = DefaultPageSize,
  ascendingOrder = true
): ArchiveDriverResult[seq[ArchiveRow]] {.base.} = discard


method getMessagesCount*(driver: ArchiveDriver): ArchiveDriverResult[int64] {.base.} = discard

method getOldestMessageTimestamp*(driver: ArchiveDriver): ArchiveDriverResult[Timestamp] {.base.} = discard

method getNewestMessageTimestamp*(driver: ArchiveDriver): ArchiveDriverResult[Timestamp]  {.base.} = discard


method deleteMessagesOlderThanTimestamp*(driver: ArchiveDriver, ts: Timestamp): ArchiveDriverResult[void] {.base.} = discard

method deleteOldestMessagesNotWithinLimit*(driver: ArchiveDriver, limit: int): ArchiveDriverResult[void] {.base.} = discard


method close*(driver: ArchiveDriver): ArchiveDriverResult[void] {.base.} =
  ok()
