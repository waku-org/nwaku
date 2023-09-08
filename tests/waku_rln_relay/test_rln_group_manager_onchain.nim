{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, osproc, sequtils, deques, streams, strutils, tempfiles],
  stew/[results, byteutils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  json,
  libp2p/crypto/crypto,
  eth/keys
import
  ../../../waku/waku_rln_relay/protocol_types,
  ../../../waku/waku_rln_relay/constants,
  ../../../waku/waku_rln_relay/contract,
  ../../../waku/waku_rln_relay/rln,
  ../../../waku/waku_rln_relay/conversion_utils,
  ../../../waku/waku_rln_relay/group_manager/on_chain/group_manager,
  ../testlib/common,
  ./utils

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


  # encode registry contract inputs to 32 bytes zero-padded
  let
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = hasherAddressEncoded


  debug "encoded hasher address: ", hasherAddressEncoded
  debug "encoded contract input:", contractInput

  # deploy registry contract with its constructor inputs
  let receipt = await web3.deployContract(RegistryContractCode,
                                          contractInput = contractInput)
  let contractAddress = receipt.contractAddress.get()
  debug "Address of the deployed registry contract: ", contractAddress

  let registryContract = web3.contractSender(WakuRlnRegistry, contractAddress)
  let newStorageReceipt = await registryContract.newStorage().send()

  debug "Receipt of the newStorage transaction: ", newStorageReceipt
  let newBalance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Account balance after the contract deployment: ", newBalance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress


proc createEthAccount(): Future[(keys.PrivateKey, Address)] {.async.} =
  let web3 = await newWeb3(EthClient)
  let accounts = await web3.provider.eth_accounts()
  let gasPrice = int(await web3.provider.eth_gasPrice())
  web3.defaultAccount = accounts[0]

  let pk = keys.PrivateKey.random(rng[])
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
    let runGanache = startProcess("npx", args = ["--yes", "ganache@7.9.0", "--port", "8540", "--miner.blockGasLimit", "300000000000000", "--wallet.defaultBalance", "10000"], options = {poUsePath})
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
      except CatchableError:
        break
    debug "Ganache daemon is running and ready", pid=ganachePID, startLog=ganacheStartLog
    return runGanache
  except:  # TODO: Fix "BareExcept" warning
    error "Ganache daemon run failed", err = getCurrentExceptionMsg()


# Stops Ganache daemon
proc stopGanache(runGanache: Process) {.used.} =

  let ganachePID = runGanache.processID
  # We wait the daemon to exit
  try:
    # We terminate Ganache daemon by sending a SIGTERM signal to the runGanache PID to trigger RPC server termination and clean-up
    discard startProcess("pkill", args = ["-f", "ganache"], options = {poUsePath})
    debug "Sent SIGTERM to Ganache", ganachePID=ganachePID
  except:
    error "Ganache daemon termination failed: ", err = getCurrentExceptionMsg()

proc setup(): Future[OnchainGroupManager] {.async.} =
  let rlnInstanceRes = createRlnInstance(tree_path = genTempPath("rln_tree", "group_manager_onchain"))
  require:
    rlnInstanceRes.isOk()

  let rlnInstance = rlnInstanceRes.get()

  let contractAddress = await uploadRLNContract(EthClient)
  # connect to the eth client
  let web3 = await newWeb3(EthClient)

  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[0]

  var pk = none(string)
  let (privateKey, _) = await createEthAccount()
  pk = some($privateKey)

  let manager = OnchainGroupManager(ethClientUrl: EthClient,
                                    ethContractAddress: $contractAddress,
                                    ethPrivateKey: pk,
                                    rlnInstance: rlnInstance)

  return manager

suite "Onchain group manager":
  # We run Ganache
  let runGanache {.used.} = runGanache()

  asyncTest "should initialize successfully":
    let manager = await setup()
    await manager.init()

    check:
      manager.ethRpc.isSome()
      manager.rlnContract.isSome()
      manager.membershipFee.isSome()
      manager.initialized
      manager.rlnContractDeployedBlockNumber > 0

    await manager.stop()

  asyncTest "should error on initialization when loaded metadata does not match":
    let manager = await setup()
    await manager.init()

    let metadataSetRes = manager.setMetadata()
    assert metadataSetRes.isOk(), metadataSetRes.error
    let metadataRes = manager.rlnInstance.getMetadata()
    assert metadataRes.isOk(), metadataRes.error
    let metadata = metadataRes.get()
    require:
      metadata.chainId == 1337
      metadata.contractAddress == manager.ethContractAddress
    
    await manager.stop()

    let differentContractAddress = await uploadRLNContract(manager.ethClientUrl)
    # simulating a change in the contractAddress
    let manager2 = OnchainGroupManager(ethClientUrl: EthClient,
                                       ethContractAddress: $differentContractAddress,
                                       rlnInstance: manager.rlnInstance)
    expect(ValueError): await manager2.init()

  asyncTest "startGroupSync: should start group sync":
    let manager = await setup()

    await manager.init()
    await manager.startGroupSync()
    await manager.stop()

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = await setup()

    expect(ValueError):
      await manager.startGroupSync()
    await manager.stop()

  asyncTest "startGroupSync: should sync to the state of the group":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    await manager.init()

    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()

    let fut = newFuture[void]("startGroupSync")

    proc generateCallback(fut: Future[void]): OnRegisterCallback =
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        require:
          registrations.len == 1
          registrations[0].idCommitment == credentials.idCommitment
          registrations[0].index == 0
        fut.complete()
      return callback

    manager.onRegister(generateCallback(fut))

    await manager.register(credentials)
    await manager.startGroupSync()

    await fut

    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()

    check:
      merkleRootBefore != merkleRootAfter
    await manager.stop()

  asyncTest "startGroupSync: should fetch history correctly":
    let manager = await setup()
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    await manager.init()

    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()

    type TestGroupSyncFuts = array[0..credentialCount - 1, Future[void]]
    var futures: TestGroupSyncFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()
    proc generateCallback(futs: TestGroupSyncFuts, credentials: seq[IdentityCredential]): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        if registrations.len == 1 and
            registrations[0].idCommitment == credentials[futureIndex].idCommitment and
            registrations[0].index == MembershipIndex(futureIndex):
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
      manager.validRootBuffer.len() == credentialCount - AcceptableRootWindowSize
    await manager.stop()

  asyncTest "register: should guard against uninitialized state":
    let manager = await setup()
    let dummyCommitment = default(IDCommitment)

    expect(ValueError):
      await manager.register(dummyCommitment)
    await manager.stop()

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
    await manager.stop()

  asyncTest "register: callback is called":
    let manager = await setup()

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      require:
        registrations.len == 1
        registrations[0].idCommitment == idCommitment
        registrations[0].index == 0
      fut.complete()

    manager.onRegister(callback)
    await manager.init()
    await manager.startGroupSync()

    await manager.register(idCommitment)

    await fut

    check:
      manager.rlnInstance.getMetadata().get().validRoots == manager.validRoots.toSeq()
    await manager.stop()

  asyncTest "withdraw: should guard against uninitialized state":
    let manager = await setup()
    let idSecretHash = generateCredentials(manager.rlnInstance).idSecretHash

    expect(ValueError):
      await manager.withdraw(idSecretHash)
    await manager.stop()

  asyncTest "validateRoot: should validate good root":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    await manager.init()


    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
         registrations[0].idCommitment == credentials.idCommitment and
         registrations[0].index == 0:
        manager.idCredentials = some(credentials)
        manager.membershipIndex = some(registrations[0].index)
        fut.complete()

    manager.onRegister(callback)

    await manager.startGroupSync()
    await manager.register(credentials)
    await fut

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = manager.generateProof(data = messageBytes,
                                              epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    # validate the root (should be true)
    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated
    await manager.stop()

  asyncTest "validateRoot: should reject bad root":
    let manager = await setup()
    await manager.init()
    await manager.startGroupSync()

    let credentials = generateCredentials(manager.rlnInstance)

    ## Assume the registration occured out of band
    manager.idCredentials = some(credentials)
    manager.membershipIndex = some(MembershipIndex(0))

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = manager.generateProof(data = messageBytes,
                                              epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    # validate the root (should be false)
    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated == false
    await manager.stop()

  asyncTest "verifyProof: should verify valid proof":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    await manager.init()

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
         registrations[0].idCommitment == credentials.idCommitment and
         registrations[0].index == 0:
        manager.idCredentials = some(credentials)
        manager.membershipIndex = some(registrations[0].index)
        fut.complete()

    manager.onRegister(callback)

    await manager.startGroupSync()
    await manager.register(credentials)
    await fut

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = manager.generateProof(data = messageBytes,
                                              epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    # verify the proof (should be true)
    let verifiedRes = manager.verifyProof(messageBytes, validProof)
    require:
      verifiedRes.isOk()

    check:
      verifiedRes.get()
    await manager.stop()

  asyncTest "verifyProof: should reject invalid proof":
    let manager = await setup()
    await manager.init()
    await manager.startGroupSync()

    let idCredential = generateCredentials(manager.rlnInstance)
    await manager.register(idCredential.idCommitment)

    let idCredential2 = generateCredentials(manager.rlnInstance)

    ## Assume the registration occured out of band
    manager.idCredentials = some(idCredential2)
    manager.membershipIndex = some(MembershipIndex(0))

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let invalidProofRes = manager.generateProof(data = messageBytes,
                                                epoch = epoch)
    require:
      invalidProofRes.isOk()
    let invalidProof = invalidProofRes.get()


    # verify the proof (should be false)
    let verifiedRes = manager.verifyProof(messageBytes, invalidProof)
    require:
      verifiedRes.isOk()

    check:
      verifiedRes.get() == false
    await manager.stop()

  asyncTest "backfillRootQueue: should backfill roots in event of chain reorg":
    let manager = await setup()
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    await manager.init()

    type TestBackfillFuts = array[0..credentialCount - 1, Future[void]]
    var futures: TestBackfillFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()

    proc generateCallback(futs: TestBackfillFuts, credentials: seq[IdentityCredential]): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        if registrations.len == 1 and
            registrations[0].idCommitment == credentials[futureIndex].idCommitment and
            registrations[0].index == MembershipIndex(futureIndex):
          futs[futureIndex].complete()
          futureIndex += 1
      return callback

    manager.onRegister(generateCallback(futures, credentials))
    await manager.startGroupSync()

    for i in 0 ..< credentials.len():
      await manager.register(credentials[i])

    await allFutures(futures)

    # At this point, we should have a full root queue, 5 roots, and partial buffer of 1 root
    require:
      manager.validRoots.len() == credentialCount - 1
      manager.validRootBuffer.len() == 1

    # We can now simulate a chain reorg by calling backfillRootQueue
    let expectedLastRoot = manager.validRootBuffer[0]
    await manager.backfillRootQueue(1)

    # We should now have 5 roots in the queue, and no partial buffer
    check:
      manager.validRoots.len() == credentialCount - 1
      manager.validRootBuffer.len() == 0
      manager.validRoots[credentialCount - 2] == expectedLastRoot
    await manager.stop()

  asyncTest "isReady should return false if ethRpc is none":
    var manager = await setup()
    await manager.init()

    manager.ethRpc = none(Web3)

    check:
      (await manager.isReady()) == false
    await manager.stop()

  asyncTest "isReady should return false if lastSeenBlockHead > lastProcessed":
    var manager = await setup()
    await manager.init()

    check:
      (await manager.isReady()) == false
    await manager.stop()

  asyncTest "isReady should return true if ethRpc is ready":
    var manager = await setup()
    await manager.init()
    # node can only be ready after group sync is done
    await manager.startGroupSync()
    
    check:
      (await manager.isReady()) == true
    await manager.stop()


  ################################
  ## Terminating/removing Ganache
  ################################

  # We stop Ganache daemon
  stopGanache(runGanache)
