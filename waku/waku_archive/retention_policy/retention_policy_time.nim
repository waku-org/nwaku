when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/times, stew/results, chronicles, chronos
import ../../waku_core, ../driver, ../retention_policy

logScope:
  topics = "waku archive retention_policy"

const DefaultRetentionTime*: int64 = 30.days.seconds

type TimeRetentionPolicy* = ref object of RetentionPolicy
  retentionTime: chronos.Duration

proc new*(T: type TimeRetentionPolicy, retentionTime = DefaultRetentionTime): T =
  TimeRetentionPolicy(retentionTime: retentionTime.seconds)

method execute*(
    p: TimeRetentionPolicy, driver: ArchiveDriver
): Future[RetentionPolicyResult[void]] {.async.} =
  ## Delete messages that exceed the retention time by 10% and more (batch delete for efficiency)

  let omtRes = await driver.getOldestMessageTimestamp()
  if omtRes.isErr():
    info "AAA"
    return err("failed to get oldest message timestamp: " & omtRes.error)

  let now = getNanosecondTime(getTime().toUnixFloat())
  let retentionTimestamp = now - p.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - p.retentionTime.nanoseconds div 10
  info "AAA",
    now = now,
    retentionTimestamp = retentionTimestamp,
    thresholdTimestamp = thresholdTimestamp

  if thresholdTimestamp <= omtRes.value:
    info "AAA", a = thresholdTimestamp, value = omtRes.value
    return ok()

  let res = await driver.deleteMessagesOlderThanTimestamp(ts = retentionTimestamp)
  if res.isErr():
    info "AAA"
    return err("failed to delete oldest messages: " & res.error)

  return ok()
