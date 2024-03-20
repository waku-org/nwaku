import
  json_serialization,
  std/options
import
  ../waku_core

# Exactly following the RFC:
# https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/73

type

  EligibilityProof* = object
    proof*: Option[seq[byte]]

  EligibilityStatus* = object
    statusCode*: Option[uint32]
    statusDesc*: Option[string]
