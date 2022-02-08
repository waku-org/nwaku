## Contains types and utilities for pagination.
##
## Used by both message store and store protocol.

{.push raises: [Defect].}

import
  ./time, 
  nimcrypto/hash

type
  Index* = object
    ## This type contains the  description of an Index used in the pagination of WakuMessages
    digest*: MDigest[256]
    receiverTime*: Timestamp
    senderTime*: Timestamp # the time at which the message is generated