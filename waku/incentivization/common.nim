import std/options

import waku/incentivization/[rpc, eligibility_manager]

type EligibilityStatusCode* = enum
  SUCCESS = uint32(200)
  PAYMENT_REQUIRED = uint32(402)

proc init*(T: type EligibilityStatus, isEligible: bool): T =
  if isEligible:
    EligibilityStatus(statusCode: uint32(EligibilityStatusCode.SUCCESS), statusDesc: some("OK"))
  else:
    EligibilityStatus(statusCode: uint32(EligibilityStatusCode.PAYMENT_REQUIRED), statusDesc: some("Payment Required"))
