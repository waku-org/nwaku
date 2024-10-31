import std/options, chronos

import waku/incentivization/[rpc, txid_proof]

proc isEligible*(eligibilityProof: EligibilityProof, ethClient: string): Future[bool] {.async.} =
  result = await txidEligiblityCriteriaMet(eligibilityProof, ethClient)
