import std/options

import waku/incentivization/rpc

proc genEligibilityStatus*(isEligible: bool): EligibilityStatus = 
  if isEligible:
    EligibilityStatus(
      statusCode: uint32(200),
      statusDesc: some("OK"))
  else:
    EligibilityStatus(
      statusCode: uint32(402),
      statusDesc: some("Payment Required"))