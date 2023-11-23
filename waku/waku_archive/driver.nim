when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  chronos
import
  ../waku_core,
  ./common

const DefaultPageSize*: uint = 25

type
  ArchiveDriverResult*[T] = Result[T, string]
  ArchiveDriver* = ref object of RootObj
  OnErrHandler* = proc(errMsg: string) {.gcsafe, closure.}

type ArchiveRow* = (PubsubTopic, WakuMessage, seq[byte], Timestamp)

# ArchiveDriver interface

method put*(driver: ArchiveDriver,
            pubsubTopic: PubsubTopic,
            message: WakuMessage,
            digest: MessageDigest,
            messageHash: WakuMessageHash,
            receivedTime: Timestamp):
            Future[ArchiveDriverResult[void]] {.base, async.} = discard

method getAllMessages*(driver: ArchiveDriver):
                       Future[ArchiveDriverResult[seq[ArchiveRow]]] {.base, async.} = discard

method getMessages*(driver: ArchiveDriver,
                    contentTopic: seq[ContentTopic] = @[],
                    pubsubTopic = none(PubsubTopic),
                    cursor = none(ArchiveCursor),
                    startTime = none(Timestamp),
                    endTime = none(Timestamp),
                    maxPageSize = DefaultPageSize,
                    ascendingOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.base, async.} = discard

method getMessagesCount*(driver: ArchiveDriver):
                         Future[ArchiveDriverResult[int64]] {.base, async.} = discard

method getPagesCount*(driver: ArchiveDriver):
                         Future[ArchiveDriverResult[int64]] {.base, async.} = discard

method getPagesSize*(driver: ArchiveDriver):
                         Future[ArchiveDriverResult[int64]] {.base, async.} = discard

method performVacuum*(driver: ArchiveDriver):
              Future[ArchiveDriverResult[void]] {.base, async.} = discard

method getOldestMessageTimestamp*(driver: ArchiveDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.base, async.} = discard

method getNewestMessageTimestamp*(driver: ArchiveDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.base, async.} = discard

method deleteMessagesOlderThanTimestamp*(driver: ArchiveDriver,
                                         ts: Timestamp):
                                         Future[ArchiveDriverResult[void]] {.base, async.} = discard

method deleteOldestMessagesNotWithinLimit*(driver: ArchiveDriver,
                                           limit: int):
                                           Future[ArchiveDriverResult[void]] {.base, async.} = discard

method close*(driver: ArchiveDriver):
              Future[ArchiveDriverResult[void]] {.base, async.} = discard

