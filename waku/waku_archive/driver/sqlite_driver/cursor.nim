when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ../../../waku_core, ../../common

type DbCursor* = (Timestamp, seq[byte], PubsubTopic)

proc toDbCursor*(c: ArchiveCursorV2): DbCursor =
  (c.storeTime, @(c.digest.data), c.pubsubTopic)
