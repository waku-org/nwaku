when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/times,
  stew/results,
  chronicles,
  chronos,
  os
import
  ../driver,
  ../retention_policy

logScope:
  topics = "waku archive retention_policy"

# default size is 30 GiB or 32212254720.0 in bytes
const DefaultRetentionSize*: int64 = 32212254720



type
  # SizeRetentionPolicy implements auto delete as follows:
  # - sizeLimit is the size in bytes the database can grow upto
  # to reduce the size of the databases, remove the rows/number-of-messages
  # DeleteLimit is the total number of messages to delete beyond this limit
  # when the database size crosses the sizeLimit, then only a fraction of messages are kept,
  # rest of the outdated message are deleted using deleteOldestMessagesNotWithinLimit(),
  # upon deletion process the fragmented space is retrieve back using Vacuum process. 
  SizeRetentionPolicy* = ref object of RetentionPolicy
      sizeLimit: int64

proc new*(T: type SizeRetentionPolicy, size=DefaultRetentionSize): T =
  SizeRetentionPolicy(
    sizeLimit: size
  )

method execute*(p: SizeRetentionPolicy,
                driver: ArchiveDriver):
                Future[RetentionPolicyResult[void]] {.async.} =

  (await driver.decreaseDatabaseSize(p.sizeLimit)).isOkOr:
    return err("decreaseDatabaseSize failed: " & $error)

  return ok()
