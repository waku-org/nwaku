{.used.}

{.push raises: [].}

import
  std/[options, os, osproc, deques, streams, strutils, tempfiles, strformat],
  results,
  stew/byteutils,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  web3/conversions,
  web3/eth_api_types,
  json_rpc/rpcclient,
  json,
  libp2p/crypto/crypto,
  eth/keys,
  results

import
  waku/[
    waku_rln_relay,
    waku_rln_relay/protocol_types,
    waku_rln_relay/constants,
    waku_rln_relay/contract,
    waku_rln_relay/rln,
  ],
  ../testlib/common,
  ./utils

const CHAIN_ID* = 1234'u256

template skip0xPrefix(hexStr: string): int =
  ## Returns the index of the first meaningful char in `hexStr` by skipping
  ## "0x" prefix
  if hexStr.len > 1 and hexStr[0] == '0' and hexStr[1] in {'x', 'X'}: 2 else: 0

func strip0xPrefix(s: string): string =
  let prefixLen = skip0xPrefix(s)
  if prefixLen != 0:
    s[prefixLen .. ^1]
  else:
    s

proc generateCredentials*(rlnInstance: ptr RLN): IdentityCredential =
  let credRes = membershipKeyGen(rlnInstance)
  return credRes.get()

proc getRateCommitment*(
    idCredential: IdentityCredential, userMessageLimit: UserMessageLimit
): RlnRelayResult[RawRateCommitment] =
  return RateCommitment(
    idCommitment: idCredential.idCommitment, userMessageLimit: userMessageLimit
  ).toLeaf()

proc generateCredentials*(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials(rlnInstance))
  return credentials

proc getContractAddressFromDeployScriptOutput*(output: string): Result[string, string] =
  const searchStr = "Return ==\n0: address "
  let idx = output.find(searchStr)
  if idx >= 0:
    let startPos = idx + searchStr.len
    let endPos = output.find('\n', startPos)
    if (endPos - startPos) >= 42:
      let address = output[startPos ..< endPos]
      return ok(address)
  return err("Unable to find contract address in deploy script output")

proc getForgePath*(): string =
  var forgePath = ""
  if existsEnv("XDG_CONFIG_HOME"):
    forgePath = joinPath(forgePath, os.getEnv("XDG_CONFIG_HOME", ""))
  else:
    forgePath = joinPath(forgePath, os.getEnv("HOME", ""))
  forgePath = joinPath(forgePath, ".foundry/bin/forge")
  return $forgePath

contract(ERC20Token):
  proc approve(spender: Address, amount: UInt256)
  proc allowance(owner: Address, spender: Address): UInt256 {.view.}
  proc balanceOf(account: Address): UInt256 {.view.}
  proc mint(recipient: Address, amount: UInt256)

proc getTokenBalance*(
    web3: Web3, tokenAddress: Address, account: Address
): Future[UInt256] {.async.} =
  let token = web3.contractSender(ERC20Token, tokenAddress)
  return await token.balanceOf(account).call()

proc ethToWei(eth: UInt256): UInt256 =
  eth * 1000000000000000000.u256

proc sendMintCall*(
    web3: Web3,
    accountFrom: Address,
    tokenAddress: Address,
    recipientAddress: Address,
    amountTokens: UInt256,
    recipientBalanceBeforeExpectedTokens: Option[UInt256] = none(UInt256),
): Future[TxHash] {.async.} =
  # Create mint transaction
  let mintSelector = "0x40c10f19" # Pad the address and amount to 32 bytes each
  let addressHex = recipientAddress.toHex()
  let paddedAddress = addressHex.align(64, '0')

  let amountHex = amountTokens.toHex()
  let amountWithout0x =
    if amountHex.startsWith("0x"):
      amountHex[2 .. ^1]
    else:
      amountHex
  let paddedAmount = amountWithout0x.align(64, '0') # Create the call data
  let mintCallData = mintSelector & paddedAddress & paddedAmount # Get gas price
  let gasPrice = int(await web3.provider.eth_gasPrice())

  # Create the transaction
  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(tokenAddress)
  tx.value = Opt.some(0.u256) # No ETH is sent for token operations
  tx.gasPrice = Opt.some(Quantity(gasPrice))
  tx.data = Opt.some(byteutils.hexToSeqByte(mintCallData))

  debug "Sending mint call"
  # Send the transaction
  let txHash = await web3.send(tx)

  let balanceOfSelector = "0x70a08231"
  let balanceCallData = balanceOfSelector & paddedAddress

  # Wait a bit for transaction to be mined
  await sleepAsync(500.milliseconds)

  var balanceCallTx: TransactionArgs
  balanceCallTx.to = Opt.some(tokenAddress)
  balanceCallTx.data = Opt.some(byteutils.hexToSeqByte(balanceCallData))

  # Make the call to get updated balance
  let balanceResponse = await web3.provider.eth_call(balanceCallTx, "latest")

  let balanceHexStr = "0x" & byteutils.toHex(balanceResponse)
  let balanceAfterTokens = stint.parse(balanceHexStr, UInt256, 16)
  let balanceAfterExpectedTokens =
    recipientBalanceBeforeExpectedTokens.get() + amountTokens
  debug "token balance after minting", balanceAfterTokens = balanceAfterTokens
  assert balanceAfterTokens == balanceAfterExpectedTokens,
    fmt"Token balance is {balanceAfterTokens} but expected {balanceAfterExpectedTokens}"

  let balance3 = await web3.provider.eth_getBalance(recipientAddress, "latest")
  debug "sendMintCall: after mint recipientAddress account balance: ",
    recipientAddress = recipientAddress, balance = balance3

  return txHash

proc checkApproval*(
    web3: Web3, tokenAddress: Address, owner: Address, spender: Address
): Future[UInt256] {.async.} =
  let token = web3.contractSender(ERC20Token, tokenAddress)
  let allowance = await token.allowance(owner, spender).call()
  debug "Current allowance", owner = owner, spender = spender, allowance = allowance
  return allowance

proc sendApproveCall*(
    web3: Web3,
    accountFrom: Address,
    privateKey: keys.PrivateKey,
    tokenAddress: Address,
    spender: Address,
    amountWei: UInt256,
): Future[TxHash] {.async.} =
  # # ERC20 approve function signature: approve(address spender, uint256 amount)
  # # Create the contract call data
  # # Method ID for approve(address,uint256) is 0x095ea7b3

  # Temporarily set the private key
  let oldPrivateKey = web3.privateKey
  web3.privateKey = Opt.some(privateKey)
  web3.lastKnownNonce = Opt.none(Quantity) # Reset nonce tracking

  # Create approve transaction
  let approveSelector = "0x095ea7b3"

  let addressHex = spender.toHex() # Already without 0x
  let paddedAddress = addressHex.align(64, '0')
  let amountHex = amountWei.toHex()
  # let amountWithout0x =
  #   if amountHex.startsWith("0x"):
  #     amountHex[2 .. ^1]
  #   else:
  #     amountHex
  let paddedAmount = amountHex.align(64, '0')
  let approveCallData = approveSelector & paddedAddress & paddedAmount

  # Get gas price
  let gasPrice = int(await web3.provider.eth_gasPrice())

  # Create the transaction
  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(tokenAddress)
  tx.value = Opt.some(0.u256)
  tx.gasPrice = Opt.some(Quantity(gasPrice))
  tx.gas = Opt.some(Quantity(100000)) # Add gas limit
  tx.data = Opt.some(byteutils.hexToSeqByte(approveCallData))
  tx.chainId = Opt.some(Quantity(CHAIN_ID))

  debug "Sending approve call with transaction", tx = tx

  try:
    # Send will automatically sign because privateKey is set
    let txHash = await web3.send(tx)
    return txHash
  except CatchableError as e:
    error "Failed to send approve transaction", error = e.msg
    raise e
  finally:
    # Always restore the old private key
    web3.privateKey = oldPrivateKey

proc deployTestToken*(
    pk: keys.PrivateKey, acc: Address, web3: Web3
): Future[Address] {.async.} =
  ## Executes a Foundry forge script that deploys the a token contract (ERC-20) used for testing. This is a prerequisite to enable the contract deployment and this token contract address needs to be minted and approved for the accounts that need to register membership with the contract
  ## submodulePath: path to the submodule containing contract deploy scripts

  # All RLN related tests should be run from the root directory of the project
  let submodulePath = "./vendor/waku-rlnv2-contract"

  let forgePath = getForgePath()
  debug "Forge path", forgePath

  # Build the Foundry project
  let (forgeCleanOutput, forgeCleanExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} clean""")
  trace "Executed forge clean command", output = forgeCleanOutput
  if forgeCleanExitCode != 0:
    error "forge clean failed", output = forgeCleanOutput

  let (forgeInstallOutput, forgeInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} install""")
  trace "Executed forge install command", output = forgeInstallOutput
  if forgeInstallExitCode != 0:
    error "forge install failed", output = forgeInstallOutput

  let (pnpmInstallOutput, pnpmInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && pnpm install""")
  trace "Executed pnpm install command", output = pnpmInstallOutput
  if pnpmInstallExitCode != 0:
    error "pnpm install failed", output = pnpmInstallOutput

  let (forgeBuildOutput, forgeBuildExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} build""")
  trace "Executed forge build command", output = forgeBuildOutput
  if forgeBuildExitCode != 0:
    error "forge build failed", output = forgeBuildOutput

  # Set the environment variable API keys to anything for testing
  putEnv("API_KEY_CARDONA", "123")
  putEnv("API_KEY_LINEASCAN", "123")
  putEnv("API_KEY_ETHERSCAN", "123")

  # Deploy TestToken contract
  let forgeCmdTestToken =
    fmt"""cd {submodulePath} && {forgePath} script test/TestToken.sol --broadcast -vv --rpc-url http://localhost:8540 --tc TestTokenFactory --private-key {pk} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployTestToken, exitCodeDeployTestToken) = execCmdEx(forgeCmdTestToken)
  trace "Executed forge command to deploy TestToken contract",
    output = outputDeployTestToken
  if exitCodeDeployTestToken != 0:
    # error "Forge command to deploy TestToken contract failed", output = outputDeployTestToken
    raise newException(
      CatchableError,
      "Forge command to deploy TestToken contract failed, output=" &
        outputDeployTestToken,
    )

  # Parse the output to find contract address
  let testTokenAddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployTestToken)
  if testTokenAddressRes.isErr():
    error "Failed to get TestToken contract address from deploy script output"
    ##TODO: raise exception here?
  let testTokenAddress = testTokenAddressRes.get()
  debug "Address of the TestToken contract", testTokenAddress
  debug "TestToken contract deployer account details", account = acc, pk = pk

  let testTokenAddressBytes = hexToByteArray[20](testTokenAddress)
  let testTokenAddressAddress = Address(testTokenAddressBytes)

  return testTokenAddressAddress

proc approveAndVerify*(
    web3: Web3,
    accountFrom: Address,
    privateKey: keys.PrivateKey,
    tokenAddress: Address,
    spender: Address,
    amountWei: UInt256,
): Future[bool] {.async.} =
  debug "Starting approval process",
    owner = accountFrom,
    tokenAddress = tokenAddress,
    spender = spender,
    amount = amountWei

  # Send approval
  let txHash = await sendApproveCall(
    web3, accountFrom, privateKey, tokenAddress, spender, amountWei
  )

  debug "Approval transaction sent", txHash = txHash

  # Wait for transaction to be mined
  let receipt = await web3.getMinedTransactionReceipt(txHash)
  debug "Transaction mined", status = receipt.status, blockNumber = receipt.blockNumber

  # Check if status is present and successful
  if receipt.status.isNone or receipt.status.get != 1.Quantity:
    error "Approval transaction failed"
    return false

  # Give it a moment for the state to settle
  await sleepAsync(100.milliseconds)

  # Check allowance after mining
  let allowanceAfter = await checkApproval(web3, tokenAddress, accountFrom, spender)
  debug "Allowance after approval", amount = allowanceAfter

  return allowanceAfter >= amountWei

proc executeForgeContractDeployScripts*(): Future[Address] {.async.} =
  ## Executes a set of foundry forge scripts required to deploy the RLN contract and returns the deployed proxy contract address
  ## submodulePath: path to the submodule containing contract deploy scripts

  # All RLN related tests should be run from the root directory of the project
  let submodulePath = "./vendor/waku-rlnv2-contract"
  # Default Anvil account[1] privatekey
  let PRIVATE_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  let forgePath = getForgePath()
  debug "Forge path", forgePath

  # Build the Foundry project
  let (forgeCleanOutput, forgeCleanExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} clean""")
  trace "Executed forge clean command", output = forgeCleanOutput
  if forgeCleanExitCode != 0:
    error "forge clean failed", output = forgeCleanOutput

  let (forgeInstallOutput, forgeInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} install""")
  trace "Executed forge install command", output = forgeInstallOutput
  if forgeInstallExitCode != 0:
    error "forge install failed", output = forgeInstallOutput

  let (pnpmInstallOutput, pnpmInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && pnpm install""")
  trace "Executed pnpm install command", output = pnpmInstallOutput
  if pnpmInstallExitCode != 0:
    error "pnpm install failed", output = pnpmInstallOutput

  let (forgeBuildOutput, forgeBuildExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} build""")
  trace "Executed forge build command", output = forgeBuildOutput
  if forgeBuildExitCode != 0:
    error "forge build failed", output = forgeBuildOutput

  # Set the environment variable API keys to anything for testing
  putEnv("API_KEY_CARDONA", "123")
  putEnv("API_KEY_LINEASCAN", "123")
  putEnv("API_KEY_ETHERSCAN", "123")

  # Deploy LinearPriceCalculator contract
  let forgeCmdPriceCalculator =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vv --rpc-url http://localhost:8540 --tc DeployPriceCalculator --private-key {PRIVATE_KEY} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployPriceCalculator, exitCodeDeployPriceCalculator) =
    execCmdEx(forgeCmdPriceCalculator)
  trace "Executed forge command to deploy LinearPriceCalculator contract",
    output = outputDeployPriceCalculator
  if exitCodeDeployPriceCalculator != 0:
    error "Forge command to deploy LinearPriceCalculator contract failed",
      output = outputDeployPriceCalculator

  # Parse the output to find contract address
  let priceCalculatorAddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployPriceCalculator)
  if priceCalculatorAddressRes.isErr():
    error "Failed to get LinearPriceCalculator contract address from deploy script output"
    ##TODO: raise exception here?
  let priceCalculatorAddress = priceCalculatorAddressRes.get()
  debug "Address of the LinearPriceCalculator contract", priceCalculatorAddress
  putEnv("PRICE_CALCULATOR_ADDRESS", priceCalculatorAddress)

  let forgeCmdWakuRln =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vv --rpc-url http://localhost:8540 --tc DeployWakuRlnV2 --private-key {PRIVATE_KEY} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployWakuRln, exitCodeDeployWakuRln) = execCmdEx(forgeCmdWakuRln)
  trace "Executed forge command to deploy WakuRlnV2 contract",
    output = outputDeployWakuRln
  if exitCodeDeployWakuRln != 0:
    error "Forge command to deploy WakuRlnV2 contract failed",
      output = outputDeployWakuRln

  # Parse the output to find contract address
  let wakuRlnV2AddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployWakuRln)
  if wakuRlnV2AddressRes.isErr():
    error "Failed to get WakuRlnV2 contract address from deploy script output"
    ##TODO: raise exception here?
  let wakuRlnV2Address = wakuRlnV2AddressRes.get()
  debug "Address of the WakuRlnV2 contract", wakuRlnV2Address
  putEnv("WAKURLNV2_ADDRESS", wakuRlnV2Address)

  # Deploy Proxy contract
  let forgeCmdProxy =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vv --rpc-url http://localhost:8540 --tc DeployProxy --private-key {PRIVATE_KEY} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployProxy, exitCodeDeployProxy) = execCmdEx(forgeCmdProxy)
  trace "Executed forge command to deploy proxy contract", output = outputDeployProxy
  if exitCodeDeployProxy != 0:
    error "Forge command to deploy Proxy failed"
    raise newException(
      CatchableError,
      "Forge command to deploy proxy contract failed, exitCodeDeployProxy=",
    )

  let proxyAddress = getContractAddressFromDeployScriptOutput(outputDeployProxy)
  let proxyAddressBytes = hexToByteArray[20](proxyAddress.get())
  let proxyAddressAddress = Address(proxyAddressBytes)

  info "Address of the Proxy contract", proxyAddressAddress

  return proxyAddressAddress

#  a util function used for testing purposes
#  it deploys membership contract on Anvil (or any Eth client available on EthClient address)
#  must be edited if used for a different contract than membership contract
# <the difference between this and rln-v1 is that there is no need to deploy the poseidon hasher contract>
proc uploadRLNContract*(ethClientAddress: string): Future[Address] {.async.} =
  let web3 = await newWeb3(ethClientAddress)
  debug "web3 connected to", ethClientAddress

  # fetch the list of registered accounts
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]
  let add = web3.defaultAccount
  debug "contract deployer account address ", add

  let balance =
    await web3.provider.eth_getBalance(web3.defaultAccount, blockId("latest"))
  debug "Initial account balance: ", balance

  # deploy poseidon hasher bytecode
  let poseidonT3Receipt = await web3.deployContract(PoseidonT3)
  let poseidonT3Address = poseidonT3Receipt.contractAddress.get()
  let poseidonAddressStripped = strip0xPrefix($poseidonT3Address)

  # deploy lazy imt bytecode
  let lazyImtReceipt = await web3.deployContract(
    LazyIMT.replace("__$PoseidonT3$__", poseidonAddressStripped)
  )
  let lazyImtAddress = lazyImtReceipt.contractAddress.get()
  let lazyImtAddressStripped = strip0xPrefix($lazyImtAddress)

  # deploy waku rlnv2 contract
  let wakuRlnContractReceipt = await web3.deployContract(
    WakuRlnV2Contract.replace("__$PoseidonT3$__", poseidonAddressStripped).replace(
      "__$LazyIMT$__", lazyImtAddressStripped
    )
  )
  let wakuRlnContractAddress = wakuRlnContractReceipt.contractAddress.get()
  let wakuRlnAddressStripped = strip0xPrefix($wakuRlnContractAddress)

  debug "Address of the deployed rlnv2 contract: ", wakuRlnContractAddress

  # need to send concat: impl & init_bytes
  let contractInput =
    byteutils.toHex(encode(wakuRlnContractAddress)) & Erc1967ProxyContractInput
  debug "contractInput", contractInput
  let proxyReceipt =
    await web3.deployContract(Erc1967Proxy, contractInput = contractInput)

  debug "proxy receipt", contractAddress = proxyReceipt.contractAddress.get()
  let proxyAddress = proxyReceipt.contractAddress.get()

  let newBalance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Account balance after the contract deployment: ", newBalance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return proxyAddress

proc sendEthTransfer*(
    web3: Web3,
    accountFrom: Address,
    accountTo: Address,
    amountWei: UInt256,
    accountToBalanceBeforeExpectedWei: Option[UInt256] = none(UInt256),
): Future[TxHash] {.async.} =
  let doBalanceAssert = accountToBalanceBeforeExpectedWei.isSome()

  if doBalanceAssert:
    let balanceBeforeWei = await web3.provider.eth_getBalance(accountTo, "latest")
    let balanceBeforeExpectedWei = accountToBalanceBeforeExpectedWei.get()
    assert balanceBeforeWei == balanceBeforeExpectedWei,
      fmt"Balance is {balanceBeforeWei} before transfer but expected {balanceBeforeExpectedWei}"

  let gasPrice = int(await web3.provider.eth_gasPrice())

  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(accountTo)
  tx.value = Opt.some(amountWei)
  tx.gasPrice = Opt.some(Quantity(gasPrice))

  # TODO: handle the error if sending fails
  let txHash = await web3.send(tx)

  # Wait a bit for transaction to be mined
  await sleepAsync(2000.milliseconds)

  if doBalanceAssert:
    let balanceAfterWei = await web3.provider.eth_getBalance(accountTo, "latest")
    let balanceAfterExpectedWei = accountToBalanceBeforeExpectedWei.get() + amountWei
    assert balanceAfterWei == balanceAfterExpectedWei,
      fmt"Balance is {balanceAfterWei} after transfer but expected {balanceAfterExpectedWei}"

  return txHash

proc createEthAccount*(
    ethAmount: UInt256 = 1000.u256
): Future[(keys.PrivateKey, Address)] {.async.} =
  let web3 = await newWeb3(EthClient)
  let accounts = await web3.provider.eth_accounts()
  let gasPrice = Quantity(await web3.provider.eth_gasPrice())
  web3.defaultAccount = accounts[0]

  let pk = keys.PrivateKey.random(rng[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  var tx: TransactionArgs
  tx.`from` = Opt.some(accounts[0])
  tx.value = Opt.some(ethToWei(ethAmount))
  tx.to = Opt.some(acc)
  tx.gasPrice = Opt.some(Quantity(gasPrice))

  # Send ethAmount to acc
  discard await web3.send(tx)
  let balance = await web3.provider.eth_getBalance(acc, "latest")
  assert balance == ethToWei(ethAmount),
    fmt"Balance is {balance} but expected {ethToWei(ethAmount)}"

  return (pk, acc)

proc createEthAccount*(web3: Web3): (keys.PrivateKey, Address) =
  let pk = keys.PrivateKey.random(rng[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  return (pk, acc)

proc getAnvilPath*(): string =
  var anvilPath = ""
  if existsEnv("XDG_CONFIG_HOME"):
    anvilPath = joinPath(anvilPath, os.getEnv("XDG_CONFIG_HOME", ""))
  else:
    anvilPath = joinPath(anvilPath, os.getEnv("HOME", ""))
  anvilPath = joinPath(anvilPath, ".foundry/bin/anvil")
  return $anvilPath

# Runs Anvil daemon
proc runAnvil*(port: int = 8540, chainId: string = "1234"): Process =
  # Passed options are
  # --port                            Port to listen on.
  # --gas-limit                       Sets the block gas limit in WEI.
  # --balance                         The default account balance, specified in ether.
  # --chain-id                        Chain ID of the network.
  # See anvil documentation https://book.getfoundry.sh/reference/anvil/ for more details
  try:
    let anvilPath = getAnvilPath()
    debug "Anvil path", anvilPath
    let runAnvil = startProcess(
      anvilPath,
      args = [
        "--port",
        "8540",
        "--gas-limit",
        "300000000000000",
        "--balance",
        "1000000000",
        "--chain-id",
        $CHAIN_ID,
      ],
      options = {poUsePath},
    )
    let anvilPID = runAnvil.processID

    # We read stdout from Anvil to see when daemon is ready
    var anvilStartLog: string
    var cmdline: string
    while true:
      try:
        if runAnvil.outputstream.readLine(cmdline):
          anvilStartLog.add(cmdline)
          if cmdline.contains("Listening on 127.0.0.1:" & $port):
            break
      except Exception, CatchableError:
        break
    debug "Anvil daemon is running and ready", pid = anvilPID, startLog = anvilStartLog
    return runAnvil
  except: # TODO: Fix "BareExcept" warning
    error "Anvil daemon run failed", err = getCurrentExceptionMsg()

# Stops Anvil daemon
proc stopAnvil*(runAnvil: Process) {.used.} =
  let anvilPID = runAnvil.processID
  # We wait the daemon to exit
  try:
    # We terminate Anvil daemon by sending a SIGTERM signal to the runAnvil PID to trigger RPC server termination and clean-up
    kill(runAnvil)
    debug "Sent SIGTERM to Anvil", anvilPID = anvilPID
  except:
    error "Anvil daemon termination failed: ", err = getCurrentExceptionMsg()

proc setupOnchainGroupManager*(
    ethClientUrl: string = EthClient, amountEth: UInt256 = 10.u256
): Future[OnchainGroupManager] {.async.} =
  let rlnInstanceRes =
    createRlnInstance(tree_path = genTempPath("rln_tree", "group_manager_onchain"))
  check:
    rlnInstanceRes.isOk()

  let rlnInstance = rlnInstanceRes.get()

  # connect to the eth client
  let web3 = await newWeb3(ethClientUrl)

  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]

  let (privateKey, acc) = createEthAccount(web3)

  # we just need to fund the default account
  # the send procedure returns a tx hash that we don't use, hence discard
  discard await sendEthTransfer(
    web3, web3.defaultAccount, acc, ethToWei(5000.u256), some(0.u256)
  )

  let testTokenAddress = await deployTestToken(privateKey, acc, web3)
  putEnv("TOKEN_ADDRESS", testTokenAddress.toHex())

  discard await sendMintCall(
    web3, web3.defaultAccount, testTokenAddress, acc, ethToWei(1000.u256), some(0.u256)
  )
  let contractAddress = await executeForgeContractDeployScripts()

  let approvalSuccess = await approveAndVerify(
    web3,
    acc, # owner
    privateKey,
    testTokenAddress, # ERC20 token address
    contractAddress, # spender - the proxy contract that will spend the tokens
    ethToWei(500.u256),
  )

  # Also check the token balance
  let tokenBalance = await getTokenBalance(web3, testTokenAddress, acc)
  debug "Token balance before register", owner = acc, balance = tokenBalance

  let manager = OnchainGroupManager(
    ethClientUrls: @[ethClientUrl],
    ethContractAddress: $contractAddress,
    chainId: CHAIN_ID,
    ethPrivateKey: some($privateKey),
    rlnInstance: rlnInstance,
    onFatalErrorAction: proc(errStr: string) =
      raiseAssert errStr
    ,
  )

  return manager

{.pop.}
