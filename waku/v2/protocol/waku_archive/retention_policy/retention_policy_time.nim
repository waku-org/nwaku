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
  ../../../utils/time,
  ../driver,
  ../retention_policy

logScope:
  topics = "waku archive retention_policy"


const DefaultRetentionTime*: int64 = 30.days.seconds


type TimeRetentionPolicy* = ref object of RetentionPolicy
      retentionTime: chronos.Duration


proc init*(T: type TimeRetentionPolicy, retentionTime=DefaultRetentionTime): T =
  TimeRetentionPolicy(
    retentionTime: retentionTime.seconds
  )


method execute*(p: TimeRetentionPolicy, driver: ArchiveDriver): RetentionPolicyResult[void] =
  ## Delete messages that exceed the retention time by 10% and more (batch delete for efficiency)

  let oldestReceiverTimestamp = ?driver.getOldestMessageTimestamp().mapErr(proc(err: string): string = "failed to get oldest message timestamp: " & err)

  let now = getNanosecondTime(getTime().toUnixFloat())
  let retentionTimestamp = now - p.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - p.retentionTime.nanoseconds div 10

  if thresholdTimestamp <= oldestReceiverTimestamp:
    return ok()

  let res = driver.deleteMessagesOlderThanTimestamp(ts=retentionTimestamp)
  if res.isErr():
    return err("failed to delete oldest messages: " & res.error())

  ok()
