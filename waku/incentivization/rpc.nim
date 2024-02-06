import
  json_serialization,
  std/options
import
  ../waku_core

type
  EligibilityProofType* {.pure.} = enum
    # Indicates the type of eligibility proof
    NONE = uint32(0)
    TX_ID = uint32(1)

  EligibilityProof* = object
    proofType*: EligibilityProofType
    proof*: string # or bytes?

  DummyRequest* = object
    requestId*: string
    eligibilityProof*: Option[EligibilityProof]

  EligibilityStatus* = object
    statusCode*: uint32
    statusDesc*: string # should descripiton be optional?

  DummyResponse* = object
    requestId*: string
    eligibilityStatus*: Option[EligibilityStatus]
