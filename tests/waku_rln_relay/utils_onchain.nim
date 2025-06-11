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
  eth/keys

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

proc getPnpmPath*(): string =
  # Try multiple common pnpm installation paths in order of preference
  let homeDir = getEnv("HOME", "")
  let xdgDataHome = getEnv("XDG_DATA_HOME", joinPath(homeDir, ".local", "share"))

  let possiblePaths = [
    # Check if pnpm is in PATH first (most reliable)
    "pnpm",
    # Self-installer locations (most common for CI/automated installs)
    joinPath(xdgDataHome, "pnpm", "pnpm"),
    joinPath(xdgDataHome, "pnpm", "bin", "pnpm"),
    joinPath(homeDir, ".local", "share", "pnpm", "pnpm"),
    joinPath(homeDir, ".local", "share", "pnpm", "bin", "pnpm"),
    # Global npm installation
    joinPath(homeDir, ".npm-global", "bin", "pnpm"),
    # Local user installation via npm
    joinPath(homeDir, ".local", "bin", "pnpm"),
    # Homebrew on macOS
    "/opt/homebrew/bin/pnpm",
    "/usr/local/bin/pnpm",
    # System-wide installations
    "/usr/bin/pnpm",
    "/bin/pnpm",
  ]

  for path in possiblePaths:
    if path == "pnpm":
      # For bare "pnpm", check if it's available in PATH using which/where
      try:
        when defined(windows):
          let (output, exitCode) = execCmdEx("where pnpm 2>nul")
        else:
          let (output, exitCode) = execCmdEx("which pnpm 2>/dev/null")

        if exitCode == 0 and output.strip() != "":
          return "pnpm" # Let the shell find it in PATH
      except OSError, IOError:
        # If execCmdEx fails, continue to next path
        discard
    else:
      # For absolute paths, check if file exists
      if fileExists(path):
        return path

  # If no pnpm found, try to refresh PATH and check again
  debug "pnpm not found in any known location, waiting briefly and retrying"
  sleep(1000) # Wait 1 second for any installation to complete

  # Retry the PATH check
  try:
    when defined(windows):
      let (output, exitCode) = execCmdEx("where pnpm 2>nul")
    else:
      let (output, exitCode) = execCmdEx("which pnpm 2>/dev/null")

    if exitCode == 0 and output.strip() != "":
      debug "Found pnpm in PATH after retry", path = output.strip()
      return "pnpm"
  except OSError, IOError:
    discard

  # If still no pnpm found, return "pnpm" as fallback and let the error be more descriptive
  error "pnpm not found in any location after installation. Checked paths:",
    paths = possiblePaths
  return "pnpm"

contract(ERC20Token):
  proc allowance(owner: Address, spender: Address): UInt256 {.view.}
  proc balanceOf(account: Address): UInt256 {.view.}

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
  let doBalanceAssert = recipientBalanceBeforeExpectedTokens.isSome()

  if doBalanceAssert:
    let balanceBeforeMint = await getTokenBalance(web3, tokenAddress, recipientAddress)
    let balanceBeforeExpectedTokens = recipientBalanceBeforeExpectedTokens.get()
    assert balanceBeforeMint == balanceBeforeExpectedTokens,
      fmt"Balance is {balanceBeforeMint} before minting but expected {balanceBeforeExpectedTokens}"

  # Create mint transaction
  # Method ID for mint(address,uint256) is 0x40c10f19 which is part of the openzeppelin ERC20 standard
  # The method ID for a deployed test token can be viewed here https://sepolia.lineascan.build/address/0x185A0015aC462a0aECb81beCc0497b649a64B9ea#writeContract
  let mintSelector = "0x40c10f19"
  let addressHex = recipientAddress.toHex()
  # Pad the address and amount to 32 bytes each
  let paddedAddress = addressHex.align(64, '0')

  let amountHex = amountTokens.toHex()
  let amountWithout0x =
    if amountHex.toLower().startsWith("0x"):
      amountHex[2 .. ^1]
    else:
      amountHex
  let paddedAmount = amountWithout0x.align(64, '0')
  let mintCallData = mintSelector & paddedAddress & paddedAmount
  let gasPrice = int(await web3.provider.eth_gasPrice())

  # Create the transaction
  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(tokenAddress)
  tx.value = Opt.some(0.u256) # No ETH is sent for token operations
  tx.gasPrice = Opt.some(Quantity(gasPrice))
  tx.data = Opt.some(byteutils.hexToSeqByte(mintCallData))

  trace "Sending mint call"
  let txHash = await web3.send(tx)

  let balanceOfSelector = "0x70a08231"
  let balanceCallData = balanceOfSelector & paddedAddress

  # Wait a bit for transaction to be mined
  await sleepAsync(500.milliseconds)

  if doBalanceAssert:
    let balanceAfterMint = await getTokenBalance(web3, tokenAddress, recipientAddress)
    let balanceAfterExpectedTokens =
      recipientBalanceBeforeExpectedTokens.get() + amountTokens
    assert balanceAfterMint == balanceAfterExpectedTokens,
      fmt"Balance is {balanceAfterMint} after transfer but expected {balanceAfterExpectedTokens}"

  return txHash

# Check how many tokens a spender (the RLN contract) is allowed to spend on behalf of the owner (account which wishes to register a membership)
proc checkTokenAllowance*(
    web3: Web3, tokenAddress: Address, owner: Address, spender: Address
): Future[UInt256] {.async.} =
  let token = web3.contractSender(ERC20Token, tokenAddress)
  let allowance = await token.allowance(owner, spender).call()
  trace "Current allowance", owner = owner, spender = spender, allowance = allowance
  return allowance

proc deployTestToken*(
    pk: keys.PrivateKey, acc: Address, web3: Web3
): Future[Result[Address, string]] {.async.} =
  ## Executes a Foundry forge script that deploys the a token contract (ERC-20) used for testing. This is a prerequisite to enable the contract deployment and this token contract address needs to be minted and approved for the accounts that need to register memberships with the contract
  ## submodulePath: path to the submodule containing contract deploy scripts

  # All RLN related tests should be run from the root directory of the project
  let submodulePath = absolutePath("./vendor/waku-rlnv2-contract")

  # Verify submodule path exists
  if not dirExists(submodulePath):
    error "Submodule path does not exist", submodulePath = submodulePath
    return err("Submodule path does not exist: " & submodulePath)

  debug "Submodule path verified", submodulePath = submodulePath

  let forgePath = getForgePath()
  let pnpmPath = getPnpmPath()
  debug "Forge path", forgePath
  debug "Pnpm path", pnpmPath

  # Verify forge executable exists
  if not fileExists(forgePath):
    error "Forge executable not found", forgePath = forgePath
    return err("Forge executable not found: " & forgePath)

  # Build the Foundry project
  let (forgeCleanOutput, forgeCleanExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} clean""")
  trace "Executed forge clean command", output = forgeCleanOutput
  if forgeCleanExitCode != 0:
    return error("forge clean command failed")

  let (forgeInstallOutput, forgeInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} install""")
  trace "Executed forge install command", output = forgeInstallOutput
  if forgeInstallExitCode != 0:
    return error("forge install command failed")

  # Verify pnpm is actually executable before using it
  debug "Verifying pnpm path before use", pnpmPath = pnpmPath
  if pnpmPath != "pnpm":
    if not fileExists(pnpmPath):
      return err(fmt"pnpm executable not found at path: {pnpmPath}")
  else:
    # For bare "pnpm", try to run the install script first to ensure pnpm is available
    debug "Running pnpm install script to ensure pnpm is available"
    let installScriptPath = "./scripts/install_pnpm.sh"
    if fileExists(installScriptPath):
      let (installOutput, installExitCode) = execCmdEx(fmt"bash {installScriptPath}")
      debug "pnpm install script output",
        output = installOutput, exitCode = installExitCode

  let (pnpmInstallOutput, pnpmInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {pnpmPath} install""")
  trace "Executed pnpm install command", output = pnpmInstallOutput
  if pnpmInstallExitCode != 0:
    return
      err(fmt"pnpm install command failed using path '{pnpmPath}': {pnpmInstallOutput}")

  let (forgeBuildOutput, forgeBuildExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} build""")
  trace "Executed forge build command", output = forgeBuildOutput
  if forgeBuildExitCode != 0:
    return error("forge build command failed")

  # Set the environment variable API keys to anything for local testnet deployment
  putEnv("API_KEY_CARDONA", "123")
  putEnv("API_KEY_LINEASCAN", "123")
  putEnv("API_KEY_ETHERSCAN", "123")

  # Deploy TestToken contract
  let forgeCmdTestToken =
    fmt"""cd {submodulePath} && {forgePath} script test/TestToken.sol --broadcast -vvv --rpc-url http://localhost:8540 --tc TestTokenFactory --private-key {pk} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployTestToken, exitCodeDeployTestToken) = execCmdEx(forgeCmdTestToken)
  trace "Executed forge command to deploy TestToken contract",
    output = outputDeployTestToken
  if exitCodeDeployTestToken != 0:
    return error("Forge command to deploy TestToken contract failed")

  # Parse the command output to find contract address
  let testTokenAddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployTestToken)
  if testTokenAddressRes.isErr():
    error "Failed to get TestToken contract address from deploy script output",
      error = testTokenAddressRes.error
    return err("Failed to get TestToken contract address from deploy script output")
  let testTokenAddress = testTokenAddressRes.get()
  debug "Address of the TestToken contract", testTokenAddress

  let testTokenAddressBytes = hexToByteArray[20](testTokenAddress)
  let testTokenAddressAddress = Address(testTokenAddressBytes)
  putEnv("TOKEN_ADDRESS", testTokenAddressAddress.toHex())

  return ok(testTokenAddressAddress)

# Sends an ERC20 token approval call to allow a spender to spend a certain amount of tokens on behalf of the owner
proc approveTokenAllowanceAndVerify*(
    web3: Web3,
    accountFrom: Address,
    privateKey: keys.PrivateKey,
    tokenAddress: Address,
    spender: Address,
    amountWei: UInt256,
    expectedAllowanceBefore: Option[UInt256] = none(UInt256),
): Future[Result[TxHash, string]] {.async.} =
  var allowanceBefore: UInt256
  if expectedAllowanceBefore.isSome():
    allowanceBefore =
      await checkTokenAllowance(web3, tokenAddress, accountFrom, spender)
    let expected = expectedAllowanceBefore.get()
    if allowanceBefore != expected:
      return
        err(fmt"Allowance is {allowanceBefore} before approval but expected {expected}")

  # Temporarily set the private key
  let oldPrivateKey = web3.privateKey
  web3.privateKey = Opt.some(privateKey)
  web3.lastKnownNonce = Opt.none(Quantity)

  try:
    # ERC20 approve function signature: approve(address spender, uint256 amount)
    # Method ID for approve(address,uint256) is 0x095ea7b3
    const APPROVE_SELECTOR = "0x095ea7b3"
    let addressHex = spender.toHex().align(64, '0')
    let amountHex = amountWei.toHex().align(64, '0')
    let approveCallData = APPROVE_SELECTOR & addressHex & amountHex

    let gasPrice = await web3.provider.eth_gasPrice()

    var tx: TransactionArgs
    tx.`from` = Opt.some(accountFrom)
    tx.to = Opt.some(tokenAddress)
    tx.value = Opt.some(0.u256)
    tx.gasPrice = Opt.some(gasPrice)
    tx.gas = Opt.some(Quantity(100000))
    tx.data = Opt.some(byteutils.hexToSeqByte(approveCallData))
    tx.chainId = Opt.some(CHAIN_ID)

    trace "Sending approve call", tx = tx
    let txHash = await web3.send(tx)
    let receipt = await web3.getMinedTransactionReceipt(txHash)

    # Check transaction status
    if receipt.status.isNone or receipt.status.get != 1.Quantity:
      return err("Approval transaction failed")

    # Single verification check after mining (no extra sleep needed)
    let allowanceAfter =
      await checkTokenAllowance(web3, tokenAddress, accountFrom, spender)
    let expectedAfter =
      if expectedAllowanceBefore.isSome():
        expectedAllowanceBefore.get() + amountWei
      else:
        amountWei

    if allowanceAfter < expectedAfter:
      return err(
        fmt"Allowance is {allowanceAfter} after approval but expected at least {expectedAfter}"
      )

    return ok(txHash)
  except CatchableError as e:
    return err(fmt"Failed to send approve transaction: {e.msg}")
  finally:
    # Restore the old private key
    web3.privateKey = oldPrivateKey

proc executeForgeContractDeployScripts*(
    pk: keys.PrivateKey, acc: Address, web3: Web3
): Future[Result[Address, string]] {.async, gcsafe.} =
  ## Executes a set of foundry forge scripts required to deploy the RLN contract and returns the deployed proxy contract address
  ## submodulePath: path to the submodule containing contract deploy scripts

  # All RLN related tests should be run from the root directory of the project
  let submodulePath = "./vendor/waku-rlnv2-contract"

  # Verify submodule path exists
  if not dirExists(submodulePath):
    error "Submodule path does not exist", submodulePath = submodulePath
    return err("Submodule path does not exist: " & submodulePath)

  let privateKey = $pk
  let forgePath = getForgePath()
  debug "Forge path", forgePath

  # Verify forge executable exists
  if not fileExists(forgePath):
    error "Forge executable not found", forgePath = forgePath
    return err("Forge executable not found: " & forgePath)

  trace "contract deployer account details", account = acc, privateKey = privateKey

  # Build the Foundry project with timeout monitoring
  let forgeCleanProcess = startProcess(
    "sh",
    args = ["-c", fmt"""cd {submodulePath} && {forgePath} clean"""],
    options = {poUsePath, poStdErrToStdOut},
  )

  let startTime = Moment.now()
  let timeoutDuration = 30.seconds # 30 second timeout for clean command
  var forgeCleanOutput = ""
  var line = ""

  while forgeCleanProcess.running and (Moment.now() - startTime) < timeoutDuration:
    try:
      if forgeCleanProcess.outputStream.readLine(line):
        forgeCleanOutput.add(line & "\n")
        trace "Forge clean output line", line = line
      else:
        sleep(100)
    except:
      break

  let forgeCleanExitCode =
    if (Moment.now() - startTime) >= timeoutDuration:
      kill(forgeCleanProcess)
      close(forgeCleanProcess)
      error "Forge clean command timed out after 30 seconds"
      -1
    else:
      let exitCode = waitForExit(forgeCleanProcess)
      close(forgeCleanProcess)
      exitCode

  trace "Executed forge clean command",
    output = forgeCleanOutput, exitCode = forgeCleanExitCode
  if forgeCleanExitCode != 0:
    return error("forge clean failed")

  let (forgeInstallOutput, forgeInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} install""")
  trace "Executed forge install command", output = forgeInstallOutput
  if forgeInstallExitCode != 0:
    return error("forge install failed")

  let pnpmPath = getPnpmPath()
  debug "Pnpm path", pnpmPath
  let (pnpmInstallOutput, pnpmInstallExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {pnpmPath} install""")
  trace "Executed pnpm install command", output = pnpmInstallOutput
  if pnpmInstallExitCode != 0:
    return
      err(fmt"pnpm install command failed using path '{pnpmPath}': {pnpmInstallOutput}")

  let (forgeBuildOutput, forgeBuildExitCode) =
    execCmdEx(fmt"""cd {submodulePath} && {forgePath} build""")
  trace "Executed forge build command", output = forgeBuildOutput
  if forgeBuildExitCode != 0:
    error("forge build failed")

  # Set the environment variable API keys to anything for testing
  putEnv("API_KEY_CARDONA", "123")
  putEnv("API_KEY_LINEASCAN", "123")
  putEnv("API_KEY_ETHERSCAN", "123")

  # Deploy LinearPriceCalculator contract
  let forgeCmdPriceCalculator =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployPriceCalculator --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployPriceCalculator, exitCodeDeployPriceCalculator) =
    execCmdEx(forgeCmdPriceCalculator)
  trace "Executed forge command to deploy LinearPriceCalculator contract",
    output = outputDeployPriceCalculator
  if exitCodeDeployPriceCalculator != 0:
    return error("Forge command to deploy LinearPriceCalculator contract failed")

  # Parse the output to find contract address
  let priceCalculatorAddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployPriceCalculator)
  if priceCalculatorAddressRes.isErr():
    error "Failed to get LinearPriceCalculator contract address from deploy script output"
  let priceCalculatorAddress = priceCalculatorAddressRes.get()
  debug "Address of the LinearPriceCalculator contract", priceCalculatorAddress
  putEnv("PRICE_CALCULATOR_ADDRESS", priceCalculatorAddress)

  let forgeCmdWakuRln =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployWakuRlnV2 --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
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
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployProxy --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployProxy, exitCodeDeployProxy) = execCmdEx(forgeCmdProxy)
  trace "Executed forge command to deploy proxy contract", output = outputDeployProxy
  if exitCodeDeployProxy != 0:
    error "Forge command to deploy Proxy failed", error = outputDeployProxy
    return err("Forge command to deploy Proxy failed")

  let proxyAddress = getContractAddressFromDeployScriptOutput(outputDeployProxy)
  let proxyAddressBytes = hexToByteArray[20](proxyAddress.get())
  let proxyAddressAddress = Address(proxyAddressBytes)

  info "Address of the Proxy contract", proxyAddressAddress

  await web3.close()
  return ok(proxyAddressAddress)

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
  await sleepAsync(200.milliseconds)

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

proc checkRunningAnvilInstances*(): int =
  ## Returns the number of running Anvil processes
  try:
    when defined(windows):
      let (output, exitCode) = execCmdEx(
        "tasklist /FI \"IMAGENAME eq anvil.exe\" /FO CSV | find /C \"anvil.exe\""
      )
    else:
      let (output, exitCode) = execCmdEx("pgrep -c anvil 2>/dev/null || echo 0")

    if exitCode == 0:
      # Handle case where output might have multiple lines
      let lines = output.strip().split('\n')
      let countStr =
        if lines.len > 0:
          lines[0]
        else:
          "0"
      let count = parseInt(countStr)
      debug "Found running Anvil instances", count = count
      return count
    else:
      debug "Failed to check running Anvil instances", exitCode = exitCode
      return 0
  except ValueError:
    debug "Could not parse Anvil instance count"
    return 0
  except Exception:
    debug "Error checking Anvil instances", error = getCurrentExceptionMsg()
    return 0

proc isAnvilProcessRunning*(pid: int): bool =
  ## Checks if a specific PID is running an Anvil process
  try:
    when defined(windows):
      let (output, exitCode) = execCmdEx(
        fmt"tasklist /FI \" PID eq {pid} \ " /FI \"IMAGENAME eq anvil.exe\" /FO CSV"
      )
      result = exitCode == 0 and "anvil.exe" in output.toLower()
    else:
      let (output, exitCode) =
        execCmdEx(fmt"ps -p {pid} -o comm= 2>/dev/null | grep -q anvil")
      result = exitCode == 0

    debug "Checking if PID is running Anvil", pid = pid, isRunning = result
    return result
  except Exception:
    debug "Error checking if PID is Anvil process",
      pid = pid, error = getCurrentExceptionMsg()
    return false

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
        $port,
        "--gas-limit",
        "300000000000000",
        "--balance",
        "1000000000",
        "--chain-id",
        $chainId
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
  if runAnvil.isNil:
    debug "stopAnvil called with nil Process"
    return

  let anvilPID = runAnvil.processID
  debug "Stopping Anvil daemon", anvilPID = anvilPID

  try:
    # Send termination signals
    when not defined(windows):
      discard execCmdEx(fmt"kill -TERM {anvilPID}")
      sleep(1000)
      discard execCmdEx(fmt"kill -9 {anvilPID}")
    else:
      discard execCmdEx(fmt"taskkill /F /PID {anvilPID}")

    # Close Process object to release resources
    close(runAnvil)
    debug "Anvil daemon stopped", anvilPID = anvilPID
  except Exception as e:
    debug "Error stopping Anvil daemon", anvilPID = anvilPID, error = e.msg

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
    web3, web3.defaultAccount, acc, ethToWei(1000.u256), some(0.u256)
  )

  let testTokenAddress = (await deployTestToken(privateKey, acc, web3)).valueOr:
    assert false, "Failed to deploy test token contract: " & $error
    return

  # mint the token from the generated account
  discard await sendMintCall(
    web3, web3.defaultAccount, testTokenAddress, acc, ethToWei(1000.u256), some(0.u256)
  )
  let contractAddressRes =
    await executeForgeContractDeployScripts(privateKey, acc, web3)
  if contractAddressRes.isErr():
    error "Failed to deploy RLN contract", error = contractAddressRes.error
    raise newException(CatchableError, "Failed to deploy RLN contract")

  let contractAddress = (await executeForgeContractDeployScripts(privateKey, acc, web3)).valueOr:
    assert false, "Failed to deploy RLN contract: " & $error
    return

  # If the generated account wishes to register a membership, it needs to approve the contract to spend its tokens
  let tokenApprovalResult = await approveTokenAllowanceAndVerify(
    web3,
    acc, # owner
    privateKey,
    testTokenAddress, # ERC20 token address
    contractAddress, # spender - the proxy contract that will spend the tokens
    ethToWei(200.u256),
    some(0.u256), # expected allowance before approval
  )

  assert tokenApprovalResult.isOk, tokenApprovalResult.error()

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
