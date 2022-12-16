when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  testutils/unittests,
  stew/results,
  options,
  ../../waku/v2/protocol/waku_rln_relay/protocol_types,
  ../../waku/v2/protocol/waku_rln_relay/constants,
  ../../waku/v2/protocol/waku_rln_relay/contract,
  ../../waku/v2/protocol/waku_rln_relay/ffi,
  ../../waku/v2/protocol/waku_rln_relay/conversion_utils,
  ../../waku/v2/protocol/waku_rln_relay/group_manager/on_chain/group_manager

import
  std/[osproc, streams, strutils],
  chronos, chronicles, stint, web3, json,
  stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  eth/keys,
  ../test_helpers,
  ./test_utils

from posix import kill, SIGINT

proc generateCredentials(rlnInstance: ptr RLN): IdentityCredential =
  let credRes = membershipKeyGen(rlnInstance)
  return credRes.get()

proc generateCredentials(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials(rlnInstance))
  return credentials

#  a util function used for testing purposes
#  it deploys membership contract on Ganache (or any Eth client available on EthClient address)
#  must be edited if used for a different contract than membership contract
proc uploadRLNContract*(ethClientAddress: string): Future[Address] {.async.} =
  let web3 = await newWeb3(ethClientAddress)
  debug "web3 connected to", ethClientAddress

  # fetch the list of registered accounts
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]
  let add = web3.defaultAccount
  debug "contract deployer account address ", add

  let balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Initial account balance: ", balance

  # deploy the poseidon hash contract and gets its address
  let
    hasherReceipt = await web3.deployContract(PoseidonHasherCode)
    hasherAddress = hasherReceipt.contractAddress.get
  debug "hasher address: ", hasherAddress


  # encode membership contract inputs to 32 bytes zero-padded
  let
    membershipFeeEncoded = encode(MembershipFee).data
    depthEncoded = encode(MerkleTreeDepth.u256).data
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = membershipFeeEncoded & depthEncoded & hasherAddressEncoded


  debug "encoded membership fee: ", membershipFeeEncoded
  debug "encoded depth: ", depthEncoded
  debug "encoded hasher address: ", hasherAddressEncoded
  debug "encoded contract input:", contractInput

  # deploy membership contract with its constructor inputs
  let receipt = await web3.deployContract(MembershipContractCode,
      contractInput = contractInput)
  let contractAddress = receipt.contractAddress.get
  debug "Address of the deployed membership contract: ", contractAddress

  let newBalance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Account balance after the contract deployment: ", newBalance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress


proc createEthAccount(): Future[(keys.PrivateKey, Address)] {.async.} =
  let theRNG = keys.newRng()

  let web3 = await newWeb3(EthClient)
  let accounts = await web3.provider.eth_accounts()
  let gasPrice = int(await web3.provider.eth_gasPrice())
  web3.defaultAccount = accounts[0]

  let pk = keys.PrivateKey.random(theRNG[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  var tx:EthSend
  tx.source = accounts[0]
  tx.value = some(ethToWei(10.u256))
  tx.to = some(acc)
  tx.gasPrice = some(gasPrice)

  # Send 10 eth to acc
  discard await web3.send(tx)
  let balance = await web3.provider.eth_getBalance(acc, "latest")
  assert(balance == ethToWei(10.u256))

  return (pk, acc)


# Installs Ganache Daemon
proc installGanache() =
  # We install Ganache.
  # Packages will be installed to the ./build folder through the --prefix option
  try:
    let installGanache = startProcess("npm", args = ["install",  "ganache", "--prefix", "./build"], options = {poUsePath})
    let returnCode = installGanache.waitForExit()
    debug "Ganache install log", returnCode=returnCode, log=installGanache.outputstream.readAll()
  except:
    error "Ganache install failed"

# Uninstalls Ganache Daemon
proc uninstallGanache() =
  # We uninstall Ganache
  # Packages will be uninstalled from the ./build folder through the --prefix option.
  # Passed option is
  # --save: Package will be removed from your dependencies.
  # See npm documentation https://docs.npmjs.com/cli/v6/commands/npm-uninstall for further details
  try:
    let uninstallGanache = startProcess("npm", args = ["uninstall",  "ganache", "--save", "--prefix", "./build"], options = {poUsePath})
    let returnCode = uninstallGanache.waitForExit()
    debug "Ganache uninstall log", returnCode=returnCode, log=uninstallGanache.outputstream.readAll()
  except:
    error "Ganache uninstall failed"



# Runs Ganache daemon
proc runGanache(): Process =
  # We run directly "node node_modules/ganache/dist/node/cli.js" rather than using "npx ganache", so that the daemon does not spawn in a new child process.
  # In this way, we can directly send a SIGINT signal to the corresponding PID to gracefully terminate Ganache without dealing with multiple processes.
  # Passed options are
  # --port                            Port to listen on.
  # --miner.blockGasLimit             Sets the block gas limit in WEI.
  # --wallet.defaultBalance           The default account balance, specified in ether.
  # See ganache documentation https://www.npmjs.com/package/ganache for more details
  try:
    let runGanache = startProcess("node", args = ["./build/node_modules/ganache/dist/node/cli.js", "--port", "8540", "--miner.blockGasLimit", "300000000000000", "--wallet.defaultBalance", "10000"], options = {poUsePath})
    let ganachePID = runGanache.processID

    # We read stdout from Ganache to see when daemon is ready
    var ganacheStartLog: string
    var cmdline: string
    while true:
      try:
        if runGanache.outputstream.readLine(cmdline):
          ganacheStartLog.add(cmdline)
          if cmdline.contains("Listening on 127.0.0.1:8540"):
            break
      except:
        break
    debug "Ganache daemon is running and ready", pid=ganachePID, startLog=ganacheStartLog
    return runGanache
  except:
    error "Ganache daemon run failed"


# Stops Ganache daemon
proc stopGanache(runGanache: Process) =

  let ganachePID = runGanache.processID

  # We gracefully terminate Ganache daemon by sending a SIGINT signal to the runGanache PID to trigger RPC server termination and clean-up
  let returnCodeSIGINT = kill(ganachePID.int32, SIGINT)
  debug "Sent SIGINT to Ganache", ganachePID=ganachePID, returnCode=returnCodeSIGINT

  # We wait the daemon to exit
  try:
    let returnCodeExit = runGanache.waitForExit()
    debug "Ganache daemon terminated", returnCode=returnCodeExit
    debug "Ganache daemon run log", log=runGanache.outputstream.readAll()
  except:
    error "Ganache daemon termination failed"

proc setup(): Future[OnchainGroupManager] {.async.} =
  let rlnInstanceRes = createRlnInstance()
  require:
    rlnInstanceRes.isOk()

  let rlnInstance = rlnInstanceRes.get()

  let contractAddress = await uploadRLNContract(EthClient)
  # connect to the eth client
  let web3 = await newWeb3(EthClient)

  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]

  let (pk, _) = await createEthAccount()

  let onchainConfig = OnchainGroupManagerConfig(ethClientUrl: EthClient,
                                                ethContractAddress: $contractAddress,
                                                ethPrivateKey: some($pk))

  let manager {.used.} = OnchainGroupManager(config: onchainConfig,
                                             rlnInstance: rlnInstance)

  return manager

suite "Onchain group manager":
  # We install Ganache
  installGanache()

  # We run Ganache
  let runGanache {.used.} = runGanache()

  asyncTest "should initialize successfully":
    let manager = await setup()
    await manager.init()

    check:
      manager.config.ethRpc.isSome()
      manager.config.rlnContract.isSome()
      manager.config.membershipFee.isSome()
      manager.initialized

  asyncTest "startGroupSync: should start group sync":
    let manager = await setup()

    await manager.init()
    await manager.startGroupSync()

  # asyncTest "startGroupSync: should guard against uninitialized state":
    # let staticConfig = StaticGroupManagerConfig(groupSize: 0,
    #                                             membershipIndex: 0,
    #                                             groupKeys: @[])

    # let manager = StaticGroupManager(config: staticConfig,
    #                                  rlnInstance: rlnInstance)

    # expect(ValueError):
    #   await manager.startGroupSync()

  # asyncTest "register: should guard against uninitialized state":
    # let staticConfig = StaticGroupManagerConfig(groupSize: 0,
    #                                             membershipIndex: 0,
    #                                             groupKeys: @[])

    # let manager = StaticGroupManager(config: staticConfig,
    #                                  rlnInstance: rlnInstance)

    # let dummyCommitment = default(IDCommitment)

    # expect(ValueError):
    #   await manager.register(dummyCommitment)

  # asyncTest "register: should register successfully":
    # await manager.init()
    # await manager.startGroupSync()

    # let idCommitment = generateCredentials(manager.rlnInstance).idCommitment
    # let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    # require:
    #     merkleRootBeforeRes.isOk()
    # let merkleRootBefore = merkleRootBeforeRes.get()
    # await manager.register(idCommitment)
    # let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    # require:
    #   merkleRootAfterRes.isOk()
    # let merkleRootAfter = merkleRootAfterRes.get()
    # check:
    #   merkleRootAfter.inHex() != merkleRootBefore.inHex()
    #   manager.latestIndex == 10

  # asyncTest "register: callback is called":
    # var callbackCalled = false
    # let idCommitment = generateCredentials(manager.rlnInstance).idCommitment

    # let fut = newFuture[void]()

    # proc callback(registrations: seq[(IDCommitment, MembershipIndex)]): Future[void] {.async.} =
    #   require:
    #     registrations.len == 1
    #     registrations[0][0] == idCommitment
    #     registrations[0][1] == 10
    #   callbackCalled = true
    #   fut.complete()

    # manager.onRegister(callback)
    # await manager.init()
    # await manager.startGroupSync()

    # await manager.register(idCommitment)

    # await fut
    # check:
    #   callbackCalled

  # asyncTest "withdraw: should guard against uninitialized state":
    # let idSecretHash = credentials[0].idSecretHash

    # expect(ValueError):
    #   await manager.withdraw(idSecretHash)

  # asyncTest "withdraw: should withdraw successfully":
    # await manager.init()
    # await manager.startGroupSync()

    # let idSecretHash = credentials[0].idSecretHash
    # let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    # require:
    #   merkleRootBeforeRes.isOk()
    # let merkleRootBefore = merkleRootBeforeRes.get()
    # await manager.withdraw(idSecretHash)
    # let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    # require:
    #   merkleRootAfterRes.isOk()
    # let merkleRootAfter = merkleRootAfterRes.get()
    # check:
    #   merkleRootAfter.inHex() != merkleRootBefore.inHex()

  # asyncTest "withdraw: callback is called":
    # var callbackCalled = false
    # let idSecretHash = credentials[0].idSecretHash
    # let idCommitment = credentials[0].idCommitment
    # let fut = newFuture[void]()

    # proc callback(withdrawals: seq[(IdentitySecretHash, MembershipIndex)]): Future[void] {.async.} =
    #   require:
    #     withdrawals.len == 1
    #     withdrawals[0][0] == idCommitment
    #     withdrawals[0][1] == 0
    #   callbackCalled = true
    #   fut.complete()

    # manager.onWithdraw(callback)
    # await manager.init()
    # await manager.startGroupSync()

    # await manager.withdraw(idSecretHash)

    # await fut
    # check:
    #   callbackCalled

  ################################
  ## Terminating/removing Ganache
  ################################

  # We stop Ganache daemon
  stopGanache(runGanache)

  # We uninstall Ganache
  uninstallGanache()
