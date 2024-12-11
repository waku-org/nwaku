import std/options, chronos, web3, stew/byteutils, stint, strutils

import waku/incentivization/rpc


proc checkTxIdIsEligible(txHash: TxHash, ethClient: string): Future[bool] {.async.} =
  let web3 = await newWeb3(ethClient)
  try:
    let tx = await web3.provider.eth_getTransactionByHash(txHash)
    let txReceipt = await web3.getMinedTransactionReceipt(txHash)
    # check that it is not a contract creation tx
    let toAddressOption = txReceipt.to
    let isContractCreationTx = toAddressOption.isNone
    if isContractCreationTx:
      result = false
    else:
      # check that it is a simple transfer (not a contract call)
      # a simple transfer uses 21000 gas
      let gasUsed = txReceipt.gasUsed
      let isSimpleTransferTx = (gasUsed == Quantity(21000))
      if not isSimpleTransferTx:
        result = false
      else:
        # check that the amount is "as expected" (hard-coded for now)
        let txValue = tx.value
        let hasExpectedValue = (txValue == 200500000000005063.u256)
        # check that the to address is "as expected" (hard-coded for now)
        let toAddress = toAddressOption.get()
        let hasExpectedToAddress = (toAddress == Address.fromHex("0x5e809a85aa182a9921edd10a4163745bb3e36284"))
        result = true
  except ValueError as e:
    result = false
  await web3.close()
  result

proc txidEligiblityCriteriaMet*(
    eligibilityProof: EligibilityProof, ethClient: string
): Future[bool] {.async.} =
  if eligibilityProof.proofOfPayment.isNone():
    return false
  let txHash = TxHash.fromHex(byteutils.toHex(eligibilityProof.proofOfPayment.get()))
  let txExists = await checkTxIdIsEligible(txHash, ethClient)
  return txExists
