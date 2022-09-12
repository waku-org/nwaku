{.push raises: [Defect].}

import 
  std/times,
  stew/results,
  chronicles,
  chronos
import
  ../../../../utils/time,
  ../../sqlite,
  ../message_store,
  ../sqlite_store/queries,
  ./retention_policy

logScope:
  topics = "message_store.sqlite_store.retention_policy.time"


type TimeRetentionPolicy* = ref object of MessageRetentionPolicy
      retentionTime: chronos.Duration


proc init*(T: type TimeRetentionPolicy, retentionTime=StoreDefaultRetentionTime): T =
  TimeRetentionPolicy(
    retentionTime: retentionTime.seconds
  )


method execute*(p: TimeRetentionPolicy, db: SqliteDatabase): RetentionPolicyResult[void] =
  ## Delete messages that exceed the retention time by 10% and more (batch delete for efficiency)
  
  let oldestReceiverTimestamp = ?db.selectOldestReceiverTimestamp().mapErr(proc(err: string): string = "failed to get oldest message timestamp: " & err)

  let now = getNanosecondTime(getTime().toUnixFloat()) 
  let retentionTimestamp = now - p.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - p.retentionTime.nanoseconds div 10

  if thresholdTimestamp <= oldestReceiverTimestamp: 
    return ok()

  let res = db.deleteMessagesOlderThanTimestamp(ts=retentionTimestamp)
  if res.isErr(): 
    return err("failed to delete oldest messages: " & res.error())
  
  ok()