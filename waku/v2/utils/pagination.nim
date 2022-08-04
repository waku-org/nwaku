## Contains types and utilities for pagination.
{.push raises: [Defect].}

import
  stew/byteutils,
  nimcrypto
import
  ../protocol/waku_message,
  ./time


type Index* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  digest*: MDigest[256] # calculated over payload and content topic
  receiverTime*: Timestamp
  senderTime*: Timestamp # the time at which the message is generated
  pubsubTopic*: string


proc compute*(T: type Index, msg: WakuMessage, receivedTime: Timestamp, pubsubTopic: string): T =
  ## Takes a WakuMessage with received timestamp and returns its Index.
  ## Received timestamp will default to system time if not provided.

  let
    contentTopic = toBytes(msg.contentTopic)
    payload = msg.payload
    senderTime = msg.timestamp

  var ctx: sha256
  ctx.init()
  ctx.update(contentTopic)
  ctx.update(payload)
  let digest = ctx.finish() # computes the hash
  ctx.clear()

  Index(
    digest:digest,
    receiverTime: receivedTime, 
    senderTime: senderTime,
    pubsubTopic: pubsubTopic
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


type
  PagingDirection* {.pure.} = enum
    ## PagingDirection determines the direction of pagination
    BACKWARD = uint32(0)
    FORWARD = uint32(1)

  PagingInfo* = object
    ## This type holds the information needed for the pagination
    pageSize*: uint64
    cursor*: Index
    direction*: PagingDirection
