{.used.}

{.push raises: [].}

import
  testutils/unittests,
  results,
  options,
  waku/[
    waku_rln_relay/protocol_types,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/off_chain/group_manager,
  ]

import chronos, libp2p/crypto/crypto, eth/keys, dnsdisc/builder

import std/tempfiles

proc generateCredentials(rlnInstance: ptr RLN): IdentityCredential =
  let credRes = membershipKeyGen(rlnInstance)
  return credRes.get()

proc generateCredentials(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials(rlnInstance))
  return credentials

suite "Static group manager":
  setup:
    let rlnInstance = createRlnInstance(
      tree_path = genTempPath("rln_tree", "group_manager_static")
    ).valueOr:
      raiseAssert $error

    let credentials = generateCredentials(rlnInstance, 10)

    let manager {.used.} = OffchainGroupManager(
      rlnInstance: rlnInstance,
      groupSize: 10,
      membershipIndex: some(MembershipIndex(5)),
      groupKeys: credentials,
    )

  asyncTest "should initialize successfully":
    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    (await manager.init()).isOkOr:
      raiseAssert $error
    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    check:
      manager.idCredentials.isSome()
      manager.groupKeys.len == 10
      manager.groupSize == 10
      manager.membershipIndex == some(MembershipIndex(5))
      manager.groupKeys[5] == manager.idCredentials.get()
      manager.latestIndex == 9
      merkleRootAfter.inHex() != merkleRootBefore.inHex()

  asyncTest "startGroupSync: should start group sync":
    (await manager.init()).isOkOr:
      raiseAssert $error
    require:
      manager.validRoots.len() == 1
      manager.rlnInstance.getMerkleRoot().get() == manager.validRoots[0]

    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = OffchainGroupManager(
      groupSize: 0,
      membershipIndex: some(MembershipIndex(0)),
      groupKeys: @[],
      rlnInstance: rlnInstance,
    )

    (await manager.startGroupSync()).isErrOr:
      raiseAssert "StartGroupSync: expected error"

  asyncTest "register: should guard against uninitialized state":
    let manager = OffchainGroupManager(
      groupSize: 0,
      membershipIndex: some(MembershipIndex(0)),
      groupKeys: @[],
      rlnInstance: rlnInstance,
    )

    let dummyCommitment = default(IDCommitment)

    try:
      await manager.register(
        RateCommitment(
          idCommitment: dummyCommitment, userMessageLimit: DefaultUserMessageLimit
        )
      )
    except ValueError:
      assert true
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

  asyncTest "register: should register successfully":
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
          idCommitment: idCommitment, userMessageLimit: DefaultUserMessageLimit
        )
      )
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error
    check:
      merkleRootAfter.inHex() != merkleRootBefore.inHex()
      manager.latestIndex == 10

  asyncTest "register: callback is called":
    var callbackCalled = false
    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      require:
        registrations.len == 1
        registrations[0].index == 10
        registrations[0].rateCommitment ==
          RateCommitment(
            idCommitment: idCommitment, userMessageLimit: DefaultUserMessageLimit
          )
          .toLeaf()
          .get()
      callbackCalled = true
      fut.complete()

    try:
      manager.onRegister(callback)
      (await manager.init()).isOkOr:
        raiseAssert $error
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      await manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: DefaultUserMessageLimit
        )
      )
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut
    check:
      callbackCalled

  asyncTest "withdraw: should guard against uninitialized state":
    let idSecretHash = credentials[0].idSecretHash

    try:
      await manager.withdraw(idSecretHash)
    except ValueError:
      assert true
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

  asyncTest "withdraw: should withdraw successfully":
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let idSecretHash = credentials[0].idSecretHash
    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    try:
      await manager.withdraw(idSecretHash)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error
    check:
      merkleRootAfter.inHex() != merkleRootBefore.inHex()

  asyncTest "withdraw: callback is called":
    var callbackCalled = false
    let idSecretHash = credentials[0].idSecretHash
    let idCommitment = credentials[0].idCommitment
    let fut = newFuture[void]()

    proc callback(withdrawals: seq[Membership]): Future[void] {.async.} =
      require:
        withdrawals.len == 1
        withdrawals[0].index == 0
        withdrawals[0].rateCommitment ==
          RateCommitment(
            idCommitment: idCommitment, userMessageLimit: DefaultUserMessageLimit
          )
          .toLeaf()
          .get()

      callbackCalled = true
      fut.complete()

    try:
      manager.onWithdraw(callback)
      (await manager.init()).isOkOr:
        raiseAssert $error
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error

      await manager.withdraw(idSecretHash)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut
    check:
      callbackCalled
