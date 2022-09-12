import
  std/options,
  stew/results
import 
  ../sqlite,
  ./message_store,
  ./sqlite_store

export 
  sqlite,
  sqlite_store

{.deprecated: "import sqlite_store".}


type WakuMessageStore* {.deprecated: "use SqliteStore".} = SqliteStore

proc init*(T: type WakuMessageStore, db: SqliteDatabase, 
           capacity: int = StoreDefaultCapacity, 
           isSqliteOnly = false, 
           retentionTime = StoreDefaultRetentionTime): MessageStoreResult[T] {.deprecated: "use SqliteStore.init()".} =
  let retentionPolicy = if isSqliteOnly: TimeRetentionPolicy.init(retentionTime)
                        else: CapacityRetentionPolicy.init(capacity)

  SqliteStore.init(db, retentionPolicy=some(retentionPolicy))