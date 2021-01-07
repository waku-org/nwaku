import web3, chronos, options, stint

proc deployContract*(web3: Web3, code: string, gasPrice = 0): Future[ReceiptObject] {.async.} =
  let provider = web3.provider
  let accounts = await provider.eth_accounts()

  var code = code
  if code[1] notin {'x', 'X'}:
    code = "0x" & code
  var tr: EthSend
  tr.source = web3.defaultAccount
  tr.data = code
  tr.gas = Quantity(3000000000000).some
  if gasPrice != 0:
    tr.gasPrice = some(gasPrice)

  let r = await web3.send(tr)
  return await web3.getMinedTransactionReceipt(r)

proc ethToWei*(eth: UInt256): UInt256 =
  eth * 1000000000000000000.u256
