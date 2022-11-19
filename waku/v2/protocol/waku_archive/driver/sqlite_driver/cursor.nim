when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  ../../../../protocol/waku_message,
  ../../../../utils/time,
  ../../common

type DbCursor* = (Timestamp, seq[byte], PubsubTopic)

proc toDbCursor*(c: ArchiveCursor): DbCursor = (c.storeTime, @(c.digest.data), c.pubsubTopic)
