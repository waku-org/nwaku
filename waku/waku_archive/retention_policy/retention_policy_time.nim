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
  ../../waku_core,
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

method execute*(p: TimeRetentionPolicy,
                driver: ArchiveDriver):
                Future[RetentionPolicyResult[void]] {.async.} =
  ## Delete messages that exceed the retention time by 10% and more (batch delete for efficiency)

  let omtRes = await driver.getOldestMessageTimestamp()
  if omtRes.isErr():
    return err("failed to get oldest message timestamp: " & omtRes.error)

  let now = getNanosecondTime(getTime().toUnixFloat())
  let retentionTimestamp = now - p.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - p.retentionTime.nanoseconds div 10

  if thresholdTimestamp <= omtRes.value:
    return ok()

  let res = await driver.deleteMessagesOlderThanTimestamp(ts=retentionTimestamp)
  if res.isErr():
    return err("failed to delete oldest messages: " & res.error)

   # perform vacuum
  let resVaccum = await driver.performVacuum()
  if resVaccum.isErr():
    return err("vacuumming failed: " & resVaccum.error)

    # sleep to give it some time to complete vacuuming
  await sleepAsync(350)
  
  return ok()
