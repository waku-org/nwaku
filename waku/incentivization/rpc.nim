import json_serialization, std/options
import ../waku_core

# Implementing the RFC:
# https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/73

type
  EligibilityProof* = object
    proofOfPayment*: Option[seq[byte]]

  EligibilityStatus* = object
    statusCode*: uint32
    statusDesc*: Option[string]
