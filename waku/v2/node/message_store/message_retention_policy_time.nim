when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import 
  std/times,
  stew/results,
  chronicles,
  chronos
import
  ../../protocol/waku_store/message_store,
  ../../utils/time,
  ./message_retention_policy

logScope:
  topics = "waku node message_store retention_policy"


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