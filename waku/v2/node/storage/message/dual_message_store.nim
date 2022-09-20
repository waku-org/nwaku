{.push raises: [Defect].}

import
  std/options,
  stew/results,
  chronicles
import
  ../../../protocol/waku_message,
  ../../../utils/pagination,
  ../../../utils/time,
  ../sqlite,
  ./message_store,
  ./waku_store_queue,
  ./sqlite_store

logScope:
  topics = "message_store.dual"


type DualMessageStore* = ref object of MessageStore
    inmemory: StoreQueueRef
    persistent: SqliteStore


proc init*(T: type DualMessageStore, db: SqliteDatabase, capacity=StoreDefaultCapacity): MessageStoreResult[T] = 
  let 
    inmemory = StoreQueueRef.new(capacity)
    persistent = ?SqliteStore.init(db)

  info "loading messages from persistent storage to in-memory store"

  let res = persistent.getAllMessages()
  if res.isErr():
    warn "failed to load messages from the persistent store", err = res.error
  else: 
    for (receiverTime, msg, pubsubTopic) in res.value:
      let index = Index.compute(msg, receiverTime, pubsubTopic)
      discard inmemory.put(index, msg, pubsubTopic)

    info "successfully loaded messages from the persistent store"


  return ok(DualMessageStore(inmemory: inmemory, persistent: persistent))


method put*(s: DualMessageStore, index: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] =
  ?s.inmemory.put(index, message, pubsubTopic)
  ?s.persistent.put(index, message, pubsubTopic)
  ok()


method getAllMessages*(s: DualMessageStore): MessageStoreResult[seq[MessageStoreRow]] =
  s.inmemory.getAllMessages()


method getMessagesByHistoryQuery*(
  s: DualMessageStore,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(Index),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = StoreMaxPageSize,
  ascendingOrder = true
): MessageStoreResult[MessageStorePage] =
  s.inmemory.getMessagesByHistoryQuery(contentTopic, pubsubTopic, cursor, startTime, endTime, maxPageSize, ascendingOrder)


method getMessagesCount*(s: DualMessageStore): MessageStoreResult[int64] =
  s.inmemory.getMessagesCount()

method getOldestMessageTimestamp*(s: DualMessageStore): MessageStoreResult[Timestamp] =
  s.inmemory.getOldestMessageTimestamp()

method getNewestMessageTimestamp*(s: DualMessageStore): MessageStoreResult[Timestamp] =
  s.inmemory.getNewestMessageTimestamp()


method deleteMessagesOlderThanTimestamp*(s: DualMessageStore, ts: Timestamp): MessageStoreResult[void] =
  # NOTE: Current in-memory store deletes messages as they are inserted. This method fails with a "not implemented" error
  # ?s.inmemory.deleteMessagesOlderThanTimestamp(ts)
  ?s.persistent.deleteMessagesOlderThanTimestamp(ts)
  ok()

method deleteOldestMessagesNotWithinLimit*(s: DualMessageStore, limit: int): MessageStoreResult[void] =
  # NOTE: Current in-memory store deletes messages as they are inserted. This method fails with a "not implemented" error
  # ?s.inmemory.deleteOldestMessagesNotWithinLimit(limit)
  ?s.persistent.deleteOldestMessagesNotWithinLimit(limit)
  ok()