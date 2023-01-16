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
  ../../waku/v2/protocol/waku_rln_relay/rln,
  ../../waku/v2/protocol/waku_rln_relay/conversion_utils,
  ../../waku/v2/protocol/waku_rln_relay/group_manager/on_chain/group_manager

import
  std/[osproc, streams, strutils, sequtils],
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
    let runGanache = startProcess("npx", args = ["--yes", "ganache", "--port", "8540", "--miner.blockGasLimit", "300000000000000", "--wallet.defaultBalance", "10000"], options = {poUsePath})
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
proc stopGanache(runGanache: Process) {.used.} =

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

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = await setup()

    expect(ValueError):
      await manager.startGroupSync()

  asyncTest "startGroupSync: should sync to the state of the group":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)

    manager.idCredentials = some(credentials)
    await manager.init()

    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()

    let future = newFuture[void]("startGroupSync")

    proc generateCallback(fut: Future[void], idCommitment: IDCommitment): OnRegisterCallback =
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        require:
          registrations.len == 1
          registrations[0].idCommitment == idCommitment
          registrations[0].index == 0
        fut.complete()
      return callback

    manager.onRegister(generateCallback(future, credentials.idCommitment))
    await manager.startGroupSync()

    await future

    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()

    check:
      merkleRootBefore != merkleRootAfter

  asyncTest "startGroupSync: should fetch history correctly":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance, 5)
    await manager.init()

    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()

    var futures = [newFuture[void](), newFuture[void](), newFuture[void](), newFuture[void](), newFuture[void]()]

    proc generateCallback(futs: array[0..4, Future[system.void]], credentials: seq[IdentityCredential]): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        require:
          registrations.len == 1
          registrations[0].idCommitment == credentials[futureIndex].idCommitment
          registrations[0].index == MembershipIndex(futureIndex)
        futs[futureIndex].complete()
        futureIndex += 1
      return callback

    manager.onRegister(generateCallback(futures, credentials))
    await manager.startGroupSync()

    for i in 0 ..< credentials.len():
      await manager.register(credentials[i])

    await allFutures(futures)

    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()

    check:
      merkleRootBefore != merkleRootAfter

  asyncTest "register: should guard against uninitialized state":
    let manager = await setup()
    let dummyCommitment = default(IDCommitment)

    expect(ValueError):
      await manager.register(dummyCommitment)

  asyncTest "register: should register successfully":
    let manager = await setup()
    await manager.init()
    await manager.startGroupSync()

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment
    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
        merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()
    await manager.register(idCommitment)
    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()
    check:
      merkleRootAfter.inHex() != merkleRootBefore.inHex()
      manager.latestIndex == 1

  asyncTest "register: callback is called":
    let manager = await setup()

    var callbackCalled = false
    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      require:
        registrations.len == 1
        registrations[0].idCommitment == idCommitment
        registrations[0].index == 0
      callbackCalled = true
      fut.complete()

    manager.onRegister(callback)
    await manager.init()
    await manager.startGroupSync()

    await manager.register(idCommitment)

    await fut
    check:
      callbackCalled

  asyncTest "withdraw: should guard against uninitialized state":
    let manager = await setup()
    let idSecretHash = generateCredentials(manager.rlnInstance).idSecretHash

    expect(ValueError):
      await manager.withdraw(idSecretHash)

  ################################
  ## Terminating/removing Ganache
  ################################

  # We stop Ganache daemon
  stopGanache(runGanache)

