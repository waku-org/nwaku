{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, os, osproc, sequtils, deques, streams, strutils, tempfiles, strformat],
  stew/[results, byteutils],
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

proc getRateCommitment(
    idCredential: IdentityCredential, userMessageLimit: UserMessageLimit
): RateCommitment =
  return RateCommitment(
    idCommitment: idCredential.idCommitment, userMessageLimit: userMessageLimit
  )

proc generateCredentials(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials(rlnInstance))
  return credentials

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

  let balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Initial account balance: ", balance

  # deploy registry contract with its constructor inputs
  let receipt = await web3.deployContract(RegistryContractCode)
  let contractAddress = receipt.contractAddress.get()

  debug "Address of the deployed registry contract: ", contractAddress

  let registryContract = web3.contractSender(WakuRlnRegistry, contractAddress)
  let initReceipt = await registryContract.initialize().send()
  let newStorageReceipt = await registryContract.newStorage(20.u256).send()

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

  var tx: EthSend
  tx.source = accounts[0]
  tx.value = some(ethToWei(1000.u256))
  tx.to = some(acc)
  tx.gasPrice = some(gasPrice)

  # Send 1000 eth to acc
  discard await web3.send(tx)
  let balance = await web3.provider.eth_getBalance(acc, "latest")
  assert balance == ethToWei(1000.u256),
    fmt"Balance is {balance} but expected {ethToWei(1000.u256)}"

  return (pk, acc)

proc getAnvilPath(): string =
  var anvilPath = ""
  if existsEnv("XDG_CONFIG_HOME"):
    anvilPath = joinPath(anvilPath, os.getEnv("XDG_CONFIG_HOME", ""))
  else:
    anvilPath = joinPath(anvilPath, os.getEnv("HOME", ""))
  anvilPath = joinPath(anvilPath, ".foundry/bin/anvil")
  return $anvilPath

# Runs Anvil daemon
proc runAnvil(): Process =
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
        "--port", "8540", "--gas-limit", "300000000000000", "--balance", "1000000000",
        "--chain-id", "1337",
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
          if cmdline.contains("Listening on 127.0.0.1:8540"):
            break
      except Exception, CatchableError:
        break
    debug "Anvil daemon is running and ready", pid = anvilPID, startLog = anvilStartLog
    return runAnvil
  except: # TODO: Fix "BareExcept" warning
    error "Anvil daemon run failed", err = getCurrentExceptionMsg()

# Stops Anvil daemon
proc stopAnvil(runAnvil: Process) {.used.} =
  let anvilPID = runAnvil.processID
  # We wait the daemon to exit
  try:
    # We terminate Anvil daemon by sending a SIGTERM signal to the runAnvil PID to trigger RPC server termination and clean-up
    kill(runAnvil)
    debug "Sent SIGTERM to Anvil", anvilPID = anvilPID
  except:
    error "Anvil daemon termination failed: ", err = getCurrentExceptionMsg()

proc setup(): Future[OnchainGroupManager] {.async.} =
  let rlnInstanceRes =
    createRlnInstance(tree_path = genTempPath("rln_tree", "group_manager_onchain"))
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

  let manager = OnchainGroupManager(
    ethClientUrl: EthClient,
    ethContractAddress: $contractAddress,
    ethPrivateKey: pk,
    rlnInstance: rlnInstance,
  )

  return manager

suite "Onchain group manager":
  # We run Anvil
  let runAnvil {.used.} = runAnvil()

  asyncTest "should initialize successfully":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    check:
      manager.ethRpc.isSome()
      manager.rlnContract.isSome()
      manager.membershipFee.isSome()
      manager.initialized
      manager.rlnContractDeployedBlockNumber > 0

    await manager.stop()

  asyncTest "should error on initialization when loaded metadata does not match":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    let metadataSetRes = manager.setMetadata()
    assert metadataSetRes.isOk(), metadataSetRes.error
    let metadataOpt = manager.rlnInstance.getMetadata().valueOr:
      raiseAssert $error
    assert metadataOpt.isSome(), "metadata is not set"
    let metadata = metadataOpt.get()

    assert metadata.chainId == 1337, "chainId is not equal to 1337"
    assert metadata.contractAddress == manager.ethContractAddress,
      "contractAddress is not equal to " & manager.ethContractAddress

    await manager.stop()

    let differentContractAddress = await uploadRLNContract(manager.ethClientUrl)
    # simulating a change in the contractAddress
    let manager2 = OnchainGroupManager(
      ethClientUrl: EthClient,
      ethContractAddress: $differentContractAddress,
      rlnInstance: manager.rlnInstance,
    )
    (await manager2.init()).isErrOr:
      raiseAssert "Expected error when contract address doesn't match"

  asyncTest "should error when keystore path and password are provided but file doesn't exist":
    let manager = await setup()
    manager.keystorePath = some("/inexistent/file")
    manager.keystorePassword = some("password")

    (await manager.init()).isErrOr:
      raiseAssert "Expected error when keystore file doesn't exist"

  asyncTest "startGroupSync: should start group sync":
    let manager = await setup()

    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    await manager.stop()

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = await setup()

    (await manager.startGroupSync()).isErrOr:
      raiseAssert "Expected error when not initialized"

    await manager.stop()

  asyncTest "startGroupSync: should sync to the state of the group":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    let fut = newFuture[void]("startGroupSync")

    proc generateCallback(fut: Future[void]): OnRegisterCallback =
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        require:
          registrations.len == 1
          registrations[0].index == 0
        require:
          registrations[0].rateCommitment ==
            getRateCommitment(credentials, UserMessageLimit(1))

        require:
          registrations[0].index == 0
        fut.complete()

      return callback

    try:
      manager.onRegister(generateCallback(fut))
      await manager.register(credentials, UserMessageLimit(1))
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut

    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    let metadataOpt = manager.rlnInstance.getMetadata().valueOr:
      raiseAssert $error
    check:
      metadataOpt.get().validRoots == manager.validRoots.toSeq()
      merkleRootBefore != merkleRootAfter
    await manager.stop()

  asyncTest "startGroupSync: should fetch history correctly":
    let manager = await setup()
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    type TestGroupSyncFuts = array[0 .. credentialCount - 1, Future[void]]
    var futures: TestGroupSyncFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()
    proc generateCallback(
        futs: TestGroupSyncFuts, credentials: seq[IdentityCredential]
    ): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        if registrations.len == 1 and
            registrations[0].rateCommitment ==
            getRateCommitment(credentials[futureIndex], UserMessageLimit(1)) and
            registrations[0].index == MembershipIndex(futureIndex):
          futs[futureIndex].complete()
          futureIndex += 1

      return callback

    try:
      manager.onRegister(generateCallback(futures, credentials))
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error

      for i in 0 ..< credentials.len():
        await manager.register(credentials[i], UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await allFutures(futures)

    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    check:
      merkleRootBefore != merkleRootAfter
      manager.validRootBuffer.len() == credentialCount - AcceptableRootWindowSize
    await manager.stop()

  asyncTest "register: should guard against uninitialized state":
    let manager = await setup()
    let dummyCommitment = default(IDCommitment)

    try:
      await manager.register(
        RateCommitment(
          idCommitment: dummyCommitment, userMessageLimit: UserMessageLimit(1)
        )
      )
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await manager.stop()

  asyncTest "register: should register successfully":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment
    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    try:
      await manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
        )
      )
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error
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
      require:
        registrations[0].rateCommitment ==
          RateCommitment(
            idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
          )
        registrations[0].index == 0
      fut.complete()

    manager.onRegister(callback)
    (await manager.init()).isOkOr:
      raiseAssert $error
    try:
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      await manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
        )
      )
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check await fut.withTimeout(5.seconds)

    await manager.stop()

  asyncTest "withdraw: should guard against uninitialized state":
    let manager = await setup()
    let idSecretHash = generateCredentials(manager.rlnInstance).idSecretHash

    try:
      await manager.withdraw(idSecretHash)
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await manager.stop()

  asyncTest "validateRoot: should validate good root":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
          registrations[0].rateCommitment ==
          getRateCommitment(credentials, UserMessageLimit(1)) and
          registrations[0].index == 0:
        manager.idCredentials = some(credentials)
        fut.complete()


    manager.onRegister(callback)

    try:
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      await manager.register(credentials, UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

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
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials(manager.rlnInstance)

    ## Assume the registration occured out of band
    manager.idCredentials = some(credentials)
    manager.membershipIndex = some(MembershipIndex(0))
    manager.userMessageLimit = some(UserMessageLimit(1))

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
    )
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
    (await manager.init()).isOkOr:
      raiseAssert $error

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
          registrations[0].rateCommitment ==
          getRateCommitment(credentials, UserMessageLimit(1)) and
          registrations[0].index == 0:
        manager.idCredentials = some(credentials)
        fut.complete()


    manager.onRegister(callback)

    try:
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      await manager.register(credentials, UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    await fut

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
    )
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
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let idCredential = generateCredentials(manager.rlnInstance)

    try:
      await manager.register(getRateCommitment(idCredential, UserMessageLimit(1)))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling startGroupSync: " & getCurrentExceptionMsg()

    let idCredential2 = generateCredentials(manager.rlnInstance)

    ## Assume the registration occured out of band
    manager.idCredentials = some(idCredential2)
    manager.membershipIndex = some(MembershipIndex(0))
    manager.userMessageLimit = some(UserMessageLimit(1))

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let invalidProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
    )

    require:
      invalidProofRes.isOk()
    let invalidProof = invalidProofRes.get()

    # verify the proof (should be false)
    let verified = manager.verifyProof(messageBytes, invalidProof).valueOr:
      raiseAssert $error

    check:
      verified == false
    await manager.stop()

  asyncTest "backfillRootQueue: should backfill roots in event of chain reorg":
    let manager = await setup()
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    (await manager.init()).isOkOr:
      raiseAssert $error

    type TestBackfillFuts = array[0 .. credentialCount - 1, Future[void]]
    var futures: TestBackfillFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()

    proc generateCallback(
        futs: TestBackfillFuts, credentials: seq[IdentityCredential]
    ): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        if registrations.len == 1 and
            registrations[0].rateCommitment ==
            getRateCommitment(credentials[futureIndex], UserMessageLimit(1)) and
            registrations[0].index == MembershipIndex(futureIndex):
          futs[futureIndex].complete()
          futureIndex += 1

      return callback

    try:
      manager.onRegister(generateCallback(futures, credentials))
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error

      for i in 0 ..< credentials.len():
        await manager.register(credentials[i], UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await allFutures(futures)

    # At this point, we should have a full root queue, 5 roots, and partial buffer of 1 root
    require:
      manager.validRoots.len() == credentialCount - 1
      manager.validRootBuffer.len() == 1

    # We can now simulate a chain reorg by calling backfillRootQueue
    let expectedLastRoot = manager.validRootBuffer[0]
    try:
      await manager.backfillRootQueue(1)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    # We should now have 5 roots in the queue, and no partial buffer
    check:
      manager.validRoots.len() == credentialCount - 1
      manager.validRootBuffer.len() == 0
      manager.validRoots[credentialCount - 2] == expectedLastRoot
    await manager.stop()

  asyncTest "isReady should return false if ethRpc is none":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    manager.ethRpc = none(Web3)

    var isReady = true
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == false

    await manager.stop()

  asyncTest "isReady should return false if lastSeenBlockHead > lastProcessed":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    var isReady = true
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == false

    await manager.stop()

  asyncTest "isReady should return true if ethRpc is ready":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error
    # node can only be ready after group sync is done
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    var isReady = false
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == true

    await manager.stop()

  ################################
  ## Terminating/removing Anvil
  ################################

  # We stop Anvil daemon
  stopAnvil(runAnvil)
