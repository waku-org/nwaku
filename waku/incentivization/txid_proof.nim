import
  std/options,
  chronos,
  web3,
  stew/byteutils

import ../../../waku/incentivization/rpc

# a random confirmed txis (Sepolia)
const TxHashExisting* = TxHash.fromHex(
  "0xc1be5f442d3688a8d3e4b5980a73f15e4351358e0f16e2fdd99c2517c9cf6270"
  )
const TxHashNonExisting* = TxHash.fromHex(
  "0x0000000000000000000000000000000000000000000000000000000000000000"
  )

const EthClient = "https://sepolia.infura.io/v3/470c2e9a16f24057aee6660081729fb9"

proc genTxIdEligibilityProof*(txIdExists: bool): EligibilityProof = 
  let txHash: TxHash = (
    if txIdExists:
      TxHashExisting
    else:
      TxHashNonExisting)
  let txHashAsBytes = @(txHash.bytes())
  EligibilityProof(proofOfPayment: some(txHashAsBytes))

proc genDummyRequestWithTxIdEligibilityProof*(proofValid: bool, requestId: string = ""): DummyRequest =
  let eligibilityProof = genTxIdEligibilityProof(proofValid)
  result.requestId = requestId
  result.eligibilityProof = eligibilityProof

proc checkTxIdExists(txHash: TxHash): Future[bool] {.async.} = 
  let web3 = await newWeb3(EthClient)
  try:
    discard await web3.provider.eth_getTransactionByHash(txHash)
    result = true
  except ValueError as e:
    result = false
  await web3.close()
  result

proc txidEligiblityCriteriaMet*(eligibilityProof: EligibilityProof): Future[bool] {.async.} =
  if eligibilityProof.proofOfPayment.isNone():
    return false
  let txHash = TxHash.fromHex(byteutils.toHex(eligibilityProof.proofOfPayment.get()))
  let txExists = await checkTxIdExists(txHash)
  return txExists