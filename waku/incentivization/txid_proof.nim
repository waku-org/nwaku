import std/options, chronos, web3, stew/byteutils, stint, strutils

import waku/incentivization/rpc

const SimpleTransferGasUsed = Quantity(21000)

proc isEligibleTxId*(
    eligibilityProof: EligibilityProof,
    expectedToAddress: Address,
    expectedValue: UInt256,
    ethClient: string,
): Future[bool] {.async.} =
  ## We consider a tx eligible,
  ## in the context of service incentivization PoC,
  ## if it is confirmed and pays the expected amount to the server's address.
  ## See spec: https://github.com/waku-org/specs/blob/master/standards/core/incentivization.md
  if eligibilityProof.proofOfPayment.isNone():
    return false
  let txHash = TxHash.fromHex(byteutils.toHex(eligibilityProof.proofOfPayment.get()))
  let web3 = await newWeb3(ethClient)
  try:
    # TODO: make requests in parallel (?)
    let tx = await web3.provider.eth_getTransactionByHash(txHash)
    let txReceipt = await web3.getMinedTransactionReceipt(txHash)
    # check that it is not a contract creation tx
    let toAddressOption = txReceipt.to
    if toAddressOption.isNone:
      # this is a contract creation tx
      return false
    # check that it is a simple transfer (not a contract call)
    # a simple transfer uses 21000 gas
    let gasUsed = txReceipt.gasUsed
    let isSimpleTransferTx = (gasUsed == SimpleTransferGasUsed)
    if not isSimpleTransferTx:
      return false
    # check that the to address is "as expected"
    let toAddress = toAddressOption.get()
    let hasExpectedToAddress = (toAddress == expectedToAddress)
    # FIXME: move tx query here?
    # check that the amount is "as expected"
    let txValue = tx.value
    let hasExpectedValue = (txValue == expectedValue)
    defer:
      await web3.close()
    return hasExpectedValue and hasExpectedToAddress
  except ValueError as e:
    return false
