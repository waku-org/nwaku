## Contains types and utilities for pagination.
{.push raises: [Defect].}

import
  stew/byteutils,
  nimcrypto/sha2
import
  ../protocol/waku_message,
  ./time


type Index* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  pubsubTopic*: string
  senderTime*: Timestamp # the time at which the message is generated
  receiverTime*: Timestamp
  digest*: MDigest[256] # calculated over payload and content topic

proc computeDigest*(msg: WakuMessage): MDigest[256] =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.payload)

  # Computes the hash
  return ctx.finish()

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
