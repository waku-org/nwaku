when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import stew/results, chronicles, chronos
import ../driver, ../retention_policy

logScope:
  topics = "waku archive retention_policy"

# default size is 30 GiB or 32212254720.0 in bytes
const DefaultRetentionSize*: int64 = 32212254720

type SizeRetentionPolicy* = ref object of RetentionPolicy
  sizeLimit: int64

proc new*(T: type SizeRetentionPolicy, size = DefaultRetentionSize): T =
  SizeRetentionPolicy(sizeLimit: size)

method execute*(
    p: SizeRetentionPolicy, driver: ArchiveDriver
): Future[RetentionPolicyResult[void]] {.async.} =
  (await driver.decreaseDatabaseSize(p.sizeLimit)).isOkOr:
    return err("decreaseDatabaseSize failed: " & $error)

  return ok()
