{.push raises: [].}

import std/times, results, chronicles, chronos
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
  debug "beginning of executing message retention policy - time"

  let omtRes = await driver.getOldestMessageTimestamp()
  if omtRes.isErr():
    return err("failed to get oldest message timestamp: " & omtRes.error)

  let now = getNanosecondTime(getTime().toUnixFloat())
  let retentionTimestamp = now - p.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - p.retentionTime.nanoseconds div 10

  if thresholdTimestamp <= omtRes.value:
    return ok()

  let res = await driver.deleteMessagesOlderThanTimestamp(ts = retentionTimestamp)
  if res.isErr():
    return err("failed to delete oldest messages: " & res.error)

  debug "end of executing message retention policy - time"
  return ok()
