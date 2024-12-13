import std/options, chronos

import waku/incentivization/[rpc, txid_proof]

proc new*(T: type EligibilityStatus, isEligible: bool): T =
  if isEligible:
    EligibilityStatus(statusCode: uint32(200), statusDesc: some("OK"))
  else:
    EligibilityStatus(statusCode: uint32(402), statusDesc: some("Payment Required"))
