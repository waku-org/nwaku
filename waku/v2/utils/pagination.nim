## Contains types and utilities for pagination.
##
## Used by both message store and store protocol.

{.push raises: [Defect].}

import
  ./time, 
  nimcrypto/hash,
  stew/byteutils

export hash

type
  Index* = object
    ## This type contains the  description of an Index used in the pagination of WakuMessages
    digest*: MDigest[256] # calculated over payload and content topic
    receiverTime*: Timestamp
    senderTime*: Timestamp # the time at which the message is generated
    pubsubTopic*: string

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
