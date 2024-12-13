import std/options, chronos, web3, stew/byteutils, stint, strutils, results

import waku/incentivization/rpc

const SimpleTransferGasUsed = Quantity(21000)

proc isEligibleTxId*(
    eligibilityProof: EligibilityProof,
    expectedToAddress: Address,
    expectedValue: UInt256,
    ethClient: string,
): Future[Result[void, string]] {.async.} =
  ## We consider a tx eligible,
  ## in the context of service incentivization PoC,
  ## if it is confirmed and pays the expected amount to the server's address.
  ## See spec: https://github.com/waku-org/specs/blob/master/standards/core/incentivization.md
  if eligibilityProof.proofOfPayment.isNone():
    return err("Eligibility proof is empty")
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
      return err("A contract creation tx is not eligible")
    # check that it is a simple transfer (not a contract call)
    # a simple transfer uses 21000 gas
    let gasUsed = txReceipt.gasUsed
    let isSimpleTransferTx = (gasUsed == SimpleTransferGasUsed)
    if not isSimpleTransferTx:
      return err("A contract call tx is not eligible")
    # check that the to address is "as expected"
    let toAddress = toAddressOption.get()
    if toAddress != expectedToAddress:
      return err("Wrong destination address: " & $toAddress)
    # check that the amount is "as expected"
    let txValue = tx.value
    if txValue != expectedValue:
      return err("Wrong tx value: got " & $txValue & ", expected " & $expectedValue)
    defer:
      await web3.close()
    return ok()
  except ValueError as e:
    return err("Failed to fetch tx or tx receipt")
