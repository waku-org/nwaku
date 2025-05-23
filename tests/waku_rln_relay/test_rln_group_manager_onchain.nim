{.used.}

{.push raises: [].}

import
  std/[options, sequtils, deques, random],
  results,
  stew/byteutils,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  libp2p/crypto/crypto,
  eth/keys,
  tests/testlib/testasync,
  tests/testlib/testutils

import
  waku/[
    waku_rln_relay,
    waku_rln_relay/protocol_types,
    waku_rln_relay/constants,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain/group_manager,
  ],
  ../testlib/wakucore,
  ./utils_onchain

suite "Onchain group manager":
  # We run Anvil
  let runAnvil {.used.} = runAnvil()

  var manager {.threadvar.}: OnchainGroupManager

  asyncSetup:
    manager = await setupOnchainGroupManager()

  asyncTeardown:
    await manager.stop()

  asyncTest "should initialize successfully":
    (await manager.init()).isOkOr:
      raiseAssert $error

    check:
      manager.ethRpc.isSome()
      manager.wakuRlnContract.isSome()
      manager.initialized
      manager.rlnRelayMaxMessageLimit == 100

  asyncTest "should error on initialization when chainId does not match":
    manager.chainId = utils_onchain.CHAIN_ID + 1

    (await manager.init()).isErrOr:
      raiseAssert "Expected error when chainId does not match"

  asyncTest "should initialize when chainId is set to 0":
    manager.chainId = 0x0'u256

    (await manager.init()).isOkOr:
      raiseAssert $error

  asyncTest "should error on initialization when loaded metadata does not match":
    (await manager.init()).isOkOr:
      assert false, $error

    let metadataSetRes = manager.setMetadata()
    assert metadataSetRes.isOk(), metadataSetRes.error
    let metadataOpt = manager.rlnInstance.getMetadata().valueOr:
      assert false, $error
      return

    assert metadataOpt.isSome(), "metadata is not set"
    let metadata = metadataOpt.get()

    assert metadata.chainId == 1337, "chainId is not equal to 1337"
    assert metadata.contractAddress == manager.ethContractAddress,
      "contractAddress is not equal to " & manager.ethContractAddress

    let differentContractAddress = await uploadRLNContract(manager.ethClientUrls[0])
    # simulating a change in the contractAddress
    let manager2 = OnchainGroupManager(
      ethClientUrls: @[EthClient],
      ethContractAddress: $differentContractAddress,
      rlnInstance: manager.rlnInstance,
      onFatalErrorAction: proc(errStr: string) =
        assert false, errStr
      ,
    )
    let e = await manager2.init()
    (e).isErrOr:
      assert false, "Expected error when contract address doesn't match"

  asyncTest "should error if contract does not exist":
    manager.ethContractAddress = "0x0000000000000000000000000000000000000000"

    var triggeredError = false
    try:
      discard await manager.init()
    except CatchableError:
      triggeredError = true

    check triggeredError

  asyncTest "should error when keystore path and password are provided but file doesn't exist":
    manager.keystorePath = some("/inexistent/file")
    manager.keystorePassword = some("password")

    (await manager.init()).isErrOr:
      raiseAssert "Expected error when keystore file doesn't exist"

  asyncTest "trackRootChanges: start tracking roots":
    (await manager.init()).isOkOr:
      raiseAssert $error
    discard manager.trackRootChanges()

  asyncTest "trackRootChanges: should guard against uninitialized state":
    try:
      discard manager.trackRootChanges()
    except CatchableError:
      check getCurrentExceptionMsg().len == 38

  asyncTest "trackRootChanges: should sync to the state of the group":
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = manager.fetchMerkleRoot()

    try:
      await manager.register(credentials, UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    discard await withTimeout(trackRootChanges(manager), 15.seconds)

    let merkleRootAfter = manager.fetchMerkleRoot()

    let metadataSetRes = manager.setMetadata()
    assert metadataSetRes.isOk(), metadataSetRes.error

    let metadataOpt = getMetadata(manager.rlnInstance).valueOr:
      raiseAssert $error

    assert metadataOpt.isSome(), "metadata is not set"
    let metadata = metadataOpt.get()

    check:
      metadata.validRoots == manager.validRoots.toSeq()
      merkleRootBefore != merkleRootAfter

  asyncTest "trackRootChanges: should fetch history correctly":
    # TODO: We can't use `trackRootChanges()` directly in this test because its current implementation
    #       relies on a busy loop rather than event-based monitoring. As a result, some root changes
    #       may be missed, leading to inconsistent test results (i.e., it may randomly return true or false).
    #       To ensure reliability, we use the `updateRoots()` function to validate the `validRoots` window
    #       after each registration. 
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = manager.fetchMerkleRoot()

    try:
      for i in 0 ..< credentials.len():
        await manager.register(credentials[i], UserMessageLimit(1))
        discard await manager.updateRoots()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    let merkleRootAfter = manager.fetchMerkleRoot()

    check:
      merkleRootBefore != merkleRootAfter
      manager.validRoots.len() == credentialCount

  asyncTest "register: should guard against uninitialized state":
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

  asyncTest "register: should register successfully":
    # TODO :- similar to ```trackRootChanges: should fetch history correctly```
    (await manager.init()).isOkOr:
      raiseAssert $error

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment
    let merkleRootBefore = manager.fetchMerkleRoot()

    try:
      await manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
        )
      )
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let merkleRootAfter = manager.fetchMerkleRoot()

    check:
      merkleRootAfter != merkleRootBefore
      manager.latestIndex == 1

  asyncTest "register: callback is called":
    let idCredentials = generateCredentials(manager.rlnInstance)
    let idCommitment = idCredentials.idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      let rateCommitment = getRateCommitment(idCredentials, UserMessageLimit(1)).get()
      check:
        registrations.len == 1
        registrations[0].rateCommitment == rateCommitment
        registrations[0].index == 0
      fut.complete()

    (await manager.init()).isOkOr:
      raiseAssert $error

    manager.onRegister(callback)

    try:
      await manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
        )
      )
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut

  asyncTest "withdraw: should guard against uninitialized state":
    let idSecretHash = generateCredentials(manager.rlnInstance).idSecretHash

    try:
      await manager.withdraw(idSecretHash)
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

  asyncTest "validateRoot: should validate good root":
    let idCredentials = generateCredentials(manager.rlnInstance)
    let idCommitment = idCredentials.idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
          registrations[0].rateCommitment ==
          getRateCommitment(idCredentials, UserMessageLimit(1)).get() and
          registrations[0].index == 0:
        manager.idCredentials = some(idCredentials)
        fut.complete()

    manager.onRegister(callback)

    (await manager.init()).isOkOr:
      raiseAssert $error

    try:
      await manager.register(idCredentials, UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut

    let rootUpdated = await manager.updateRoots()

    if rootUpdated:
      let proofResult = await manager.fetchMerkleProofElements()
      if proofResult.isErr():
        error "Failed to fetch Merkle proof", error = proofResult.error
      manager.merkleProofCache = proofResult.get()
    let messageBytes = "Hello".toBytes()

    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

    check:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated

  asyncTest "validateRoot: should reject bad root":
    let idCredentials = generateCredentials(manager.rlnInstance)
    let idCommitment = idCredentials.idCommitment

    (await manager.init()).isOkOr:
      raiseAssert $error

    manager.userMessageLimit = some(UserMessageLimit(1))
    manager.membershipIndex = some(MembershipIndex(0))
    manager.idCredentials = some(idCredentials)

    manager.merkleProofCache = newSeq[byte](640)
    for i in 0 ..< 640:
      manager.merkleProofCache[i] = byte(rand(255))

    let messageBytes = "Hello".toBytes()

    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

    check:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated == false

  asyncTest "verifyProof: should verify valid proof":
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
          registrations[0].rateCommitment ==
          getRateCommitment(credentials, UserMessageLimit(1)).get() and
          registrations[0].index == 0:
        manager.idCredentials = some(credentials)
        fut.complete()

    manager.onRegister(callback)

    try:
      await manager.register(credentials, UserMessageLimit(1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    await fut

    let rootUpdated = await manager.updateRoots()

    if rootUpdated:
      let proofResult = await manager.fetchMerkleProofElements()
      if proofResult.isErr():
        error "Failed to fetch Merkle proof", error = proofResult.error
      manager.merkleProofCache = proofResult.get()

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProof = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
    ).valueOr:
      raiseAssert $error

    let verified = manager.verifyProof(messageBytes, validProof).valueOr:
      raiseAssert $error

    check:
      verified

  asyncTest "verifyProof: should reject invalid proof":
    (await manager.init()).isOkOr:
      raiseAssert $error

    let idCredential = generateCredentials(manager.rlnInstance)

    try:
      await manager.register(idCredential, UserMessageLimit(1))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling startGroupSync: " & getCurrentExceptionMsg()

    let messageBytes = "Hello".toBytes()

    let rootUpdated = await manager.updateRoots()

    manager.merkleProofCache = newSeq[byte](640)
    for i in 0 ..< 640:
      manager.merkleProofCache[i] = byte(rand(255))

    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let invalidProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
    )

    check:
      invalidProofRes.isOk()
    let invalidProof = invalidProofRes.get()

    # verify the proof (should be false)
    let verified = manager.verifyProof(messageBytes, invalidProof).valueOr:
      raiseAssert $error

    check:
      verified == false

  asyncTest "root queue should be updated correctly":
    const credentialCount = 12
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
            getRateCommitment(credentials[futureIndex], UserMessageLimit(1)).get() and
            registrations[0].index == MembershipIndex(futureIndex):
          futs[futureIndex].complete()
          futureIndex += 1

      return callback

    try:
      manager.onRegister(generateCallback(futures, credentials))

      for i in 0 ..< credentials.len():
        await manager.register(credentials[i], UserMessageLimit(1))
        discard await manager.updateRoots()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await allFutures(futures)

    check:
      manager.validRoots.len() == credentialCount

  asyncTest "isReady should return false if ethRpc is none":
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

  asyncTest "isReady should return true if ethRpc is ready":
    (await manager.init()).isOkOr:
      raiseAssert $error

    var isReady = false
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == true

  ################################
  ## Terminating/removing Anvil
  ################################

  # We stop Anvil daemon
  stopAnvil(runAnvil)
