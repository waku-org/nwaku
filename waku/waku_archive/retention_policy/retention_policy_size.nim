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

# default size is 30 Gb
const DefaultRetentionSize*: float = 30_720

# to remove 20% of the outdated data from database
const DeleteLimit = 0.80

type
  # SizeRetentionPolicy implements auto delete as follows:
  # - sizeLimit is the size in megabytes (Mbs) the database can grow upto
  # to reduce the size of the databases, remove the rows/number-of-messages
  # DeleteLimit is the total number of messages to delete beyond this limit
  # when the database size crosses the sizeLimit, then only a fraction of messages are kept,
  # rest of the outdated message are deleted using deleteOldestMessagesNotWithinLimit(),
  # upon deletion process the fragmented space is retrieve back using Vacuum process. 
  SizeRetentionPolicy* = ref object of RetentionPolicy
      sizeLimit: float

proc init*(T: type SizeRetentionPolicy, size=DefaultRetentionSize): T =
  SizeRetentionPolicy(
    sizeLimit: size
  )

method execute*(p: SizeRetentionPolicy,
                driver: ArchiveDriver):
                Future[RetentionPolicyResult[void]] {.async.} =
  ## when db size overshoots the database limit, shread 20% of outdated messages 

  # get page size of database
  let pageSizeRes = await driver.getPagesSize()
  let pageSize: int64 = int64(pageSizeRes.valueOr(0) div 1024)

  if pageSize == 0:
    return err("failed to get Page size: " & pageSizeRes.error)

  # to get the size of the database, pageCount and PageSize is required
  # get page count in "messages" database
  let pageCount = (await driver.getPagesCount()).valueOr:
    return err("failed to get Pages count: " & $error)

  # database size in megabytes (Mb)
  let totalSizeOfDB: float = float(pageSize * pageCount)/1024.0

  if totalSizeOfDB < p.sizeLimit:
    return ok()

  # to shread/delete messsges, get the total row/message count
  let numMessages = (await driver.getMessagesCount()).valueOr:
    return err("failed to get messages count: " & error)

  # NOTE: Using SQLite vacuuming is done manually, we delete a percentage of rows
  # if vacumming is done automatically then we aim to check DB size periodially for efficient
  # retention policy implementation.

  # 80% of the total messages are to be kept, delete others
  let pageDeleteWindow = int(float(numMessages) * DeleteLimit)

  (await driver.deleteOldestMessagesNotWithinLimit(limit=pageDeleteWindow)).isOkOr:
    return err("deleting oldest messages failed: " & error)

  return ok()
