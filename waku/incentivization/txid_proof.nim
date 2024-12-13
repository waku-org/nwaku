import std/options, chronos, web3, stew/byteutils, stint, strutils, results, chronicles

import waku/incentivization/rpc

const SimpleTransferGasUsed = Quantity(21000)

proc eth_getTransactionByHash_async(
    txHash: TxHash, web3: Web3
): Future[TransactionObject] {.async.} =
  await web3.provider.eth_getTransactionByHash(txHash)

proc getMinedTransactionReceipt_async(
    txHash: TxHash, web3: Web3
): Future[ReceiptObject] {.async.} =
  await web3.getMinedTransactionReceipt(txHash)

proc getTxAndTxReceipt(
    txHash: TxHash, web3: Web3
): Future[(TransactionObject, ReceiptObject)] {.async.} =
  let txFuture = eth_getTransactionByHash_async(txHash, web3)
  let receiptFuture = getMinedTransactionReceipt_async(txHash, web3)
  let tx = await txFuture
  let txReceipt = await receiptFuture
  return (tx, txReceipt)

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
  var web3: Web3
  try:
    web3 = await newWeb3(ethClient)
  except ValueError:
    let errorMsg =
      "Failed to set up a web3 provider connection: " & getCurrentExceptionMsg()
    error "exception in isEligibleTxId", error = $errorMsg
    return err($errorMsg)
  var tx: TransactionObject
  var txReceipt: ReceiptObject
  let txHash = TxHash.fromHex(byteutils.toHex(eligibilityProof.proofOfPayment.get()))
  try:
    (tx, txReceipt) = waitFor getTxAndTxReceipt(txHash, web3)
  except ValueError:
    let errorMsg = "Failed to fetch tx or tx receipt: " & getCurrentExceptionMsg()
    error "exception in isEligibleTxId", error = $errorMsg
    return err($errorMsg)
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
