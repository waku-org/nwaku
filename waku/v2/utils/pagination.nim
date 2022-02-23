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
  ## 2. receiverTimestamp (a fallback only if senderTimestamp unset and all other fields unequal)
  ## 3. message digest
  ## 4. pubsubTopic
  
  # Timestamp has a higher priority for comparison
  let timecmp = cmp(x.senderTime, y.senderTime)
  if timecmp != 0: 
    return timecmp

  # Continue only when sender timestamps are equal 
  let
    digestcmp = cmp(x.digest.data, y.digest.data)
    pstopiccmp = cmp(x.pubsubTopic, y.pubsubTopic)

  if x.senderTime == 0 and
     (digestcmp != 0 or pstopiccmp != 0):
    
    ## We sort on receiver time only if:
    ## - senderTime is unset (== 0)
    ## - message digests and pubsubTopics aren't equal (i.e. receiver time should not affect index equality, which
    ##   is based only on sender time, pubsubTopic and digest)
    let receiverTimeCmp = cmp(x.receiverTime, y.receiverTime)
    
    if receiverTimeCmp != 0:
      return receiverTimeCmp

  if digestcmp != 0:
    return digestcmp

  return pstopiccmp
