when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/byteutils,
  nimcrypto/sha2
import
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/pagination,
  ../../../utils/time


type Index* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  pubsubTopic*: string
  senderTime*: Timestamp # the time at which the message is generated
  receiverTime*: Timestamp
  digest*: MessageDigest # calculated over payload and content topic

proc compute*(T: type Index, msg: WakuMessage, receivedTime: Timestamp, pubsubTopic: string): T =
  ## Takes a WakuMessage with received timestamp and returns its Index.
  let
    digest = computeDigest(msg)
    senderTime = msg.timestamp

  Index(
    pubsubTopic: pubsubTopic,
    senderTime: senderTime,
    receiverTime: receivedTime, 
    digest: digest
  )


proc toPagingIndex*(index: Index): PagingIndex =
  PagingIndex(
    pubsubTopic: index.pubsubTopic,
    senderTime: index.senderTime,
    receiverTime: index.receiverTime,
    digest: index.digest
  )

proc toIndex*(index: PagingIndex): Index =
  Index(
    pubsubTopic: index.pubsubTopic,
    senderTime: index.senderTime,
    receiverTime: index.receiverTime,
    digest: index.digest
  )


proc `==`*(x, y: Index): bool =
  ## receiverTime plays no role in index equality
  (x.senderTime == y.senderTime) and
  (x.digest == y.digest) and
  (x.pubsubTopic == y.pubsubTopic)

proc cmp*(x, y: Index): int =
  ## compares x and y
  ## returns 0 if they are equal 
  ## returns -1 if x < y
  ## returns 1 if x > y
  ## 
  ## Default sorting order priority is:
  ## 1. senderTimestamp
  ## 2. receiverTimestamp (a fallback only if senderTimestamp unset on either side, and all other fields unequal)
  ## 3. message digest
  ## 4. pubsubTopic
  
  if x == y:
    # Quick exit ensures receiver time does not affect index equality
    return 0
  
  # Timestamp has a higher priority for comparison
  let
    # Use receiverTime where senderTime is unset
    xTimestamp = if x.senderTime == 0: x.receiverTime
                 else: x.senderTime
    yTimestamp = if y.senderTime == 0: y.receiverTime
                 else: y.senderTime

  let timecmp = cmp(xTimestamp, yTimestamp)
  if timecmp != 0: 
    return timecmp

  # Continue only when timestamps are equal 
  let digestcmp = cmp(x.digest.data, y.digest.data)
  if digestcmp != 0:
    return digestcmp
  
  return cmp(x.pubsubTopic, y.pubsubTopic)
