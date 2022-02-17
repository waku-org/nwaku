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
    digest*: MDigest[256]
    receiverTime*: Timestamp
    senderTime*: Timestamp # the time at which the message is generated

proc `==`*(x, y: Index): bool =
  ## receiverTime plays no role in index comparison
  (x.senderTime == y.senderTime) and (x.digest == y.digest)

proc cmp*(x, y: Index): int =
  ## compares x and y
  ## returns 0 if they are equal 
  ## returns -1 if x < y
  ## returns 1 if x > y
  ## receiverTime plays no role in index comparison
  
  # Timestamp has a higher priority for comparison
  let timecmp = cmp(x.senderTime, y.senderTime)
  if timecmp != 0: 
    return timecmp

  # Only when timestamps are equal 
  let digestcm = cmp(x.digest.data, y.digest.data)
  return digestcm
