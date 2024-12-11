import std/options, chronos

import waku/incentivization/[rpc, txid_proof]

proc isEligible*(eligibilityProof: EligibilityProof, ethClient: string): Future[bool] {.async.} =
  ## We consider a tx eligible,
  ## in the context of service incentivization PoC,
  ## if it is confirmed and pays the expected amount to the server's address.
  ## See spec: https://github.com/waku-org/specs/blob/master/standards/core/incentivization.md
  result = await txidEligiblityCriteriaMet(eligibilityProof, ethClient)
