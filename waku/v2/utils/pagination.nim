## Contains types and utilities for pagination.
##
## Used by both message store and store protocol.

{.push raises: [Defect].}

import nimcrypto/hash

type
  Index* = object
    ## This type contains the  description of an Index used in the pagination of WakuMessages
    digest*: MDigest[256]
    receiverTime*: int64
    senderTime*: int64 # the time at which the message is generated
