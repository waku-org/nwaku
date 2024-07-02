import
  std/options,
  chronos,
  web3,
  stew/byteutils

import ../../../waku/incentivization/rpc

proc genDummyRequestWithTxIdEligibilityProof*(txHashAsBytes: seq[byte], requestId: string = ""): DummyRequest =
  result.requestId = requestId
  result.eligibilityProof = EligibilityProof(proofOfPayment: some(txHashAsBytes))

proc checkTxIdExists(txHash: TxHash, ethClient: string): Future[bool] {.async.} = 
  let web3 = await newWeb3(ethClient)
  try:
    discard await web3.provider.eth_getTransactionByHash(txHash)
    result = true
  except ValueError as e:
    result = false
  await web3.close()
  result

proc txidEligiblityCriteriaMet*(eligibilityProof: EligibilityProof, ethClient: string): Future[bool] {.async.} =
  if eligibilityProof.proofOfPayment.isNone():
    return false
  let txHash = TxHash.fromHex(byteutils.toHex(eligibilityProof.proofOfPayment.get()))
  let txExists = await checkTxIdExists(txHash, ethClient)
  return txExists