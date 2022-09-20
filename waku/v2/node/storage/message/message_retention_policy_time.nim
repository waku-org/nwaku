{.push raises: [Defect].}

import 
  std/times,
  stew/results,
  chronicles,
  chronos
import
  ../../../utils/time,
  ./message_store,
  ./message_retention_policy

logScope:
  topics = "message_store.sqlite_store.retention_policy.time"


const StoreDefaultRetentionTime*: int64 = 30.days.seconds


type TimeRetentionPolicy* = ref object of MessageRetentionPolicy
      retentionTime: chronos.Duration


proc init*(T: type TimeRetentionPolicy, retentionTime=StoreDefaultRetentionTime): T =
  TimeRetentionPolicy(
    retentionTime: retentionTime.seconds
  )


method execute*(p: TimeRetentionPolicy, store: MessageStore): RetentionPolicyResult[void] =
  ## Delete messages that exceed the retention time by 10% and more (batch delete for efficiency)
  
  let oldestReceiverTimestamp = ?store.getOldestMessageTimestamp().mapErr(proc(err: string): string = "failed to get oldest message timestamp: " & err)

  let now = getNanosecondTime(getTime().toUnixFloat()) 
  let retentionTimestamp = now - p.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - p.retentionTime.nanoseconds div 10

  if thresholdTimestamp <= oldestReceiverTimestamp: 
    return ok()

  let res = store.deleteMessagesOlderThanTimestamp(ts=retentionTimestamp)
  if res.isErr(): 
    return err("failed to delete oldest messages: " & res.error())
  
  ok()