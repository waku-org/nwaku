when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ../../../waku_core, ../../common

type DbCursor* = (Timestamp, seq[byte], PubsubTopic)

proc toDbCursor*(c: ArchiveCursor): DbCursor =
  (c.storeTime, @(c.digest.data), c.pubsubTopic)
