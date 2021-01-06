## Contains types and utilities for pagination.
##
## Used by both message store and store protocol.

import nimcrypto/hash

type
  Index* = object
    ## This type contains the  description of an Index used in the pagination of WakuMessages
    digest*: MDigest[256]
    receivedTime*: float64
