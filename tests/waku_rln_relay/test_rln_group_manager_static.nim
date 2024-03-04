{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  testutils/unittests,
  stew/results,
  options,
  ../../../waku/waku_rln_relay/protocol_types,
  ../../../waku/waku_rln_relay/rln,
  ../../../waku/waku_rln_relay/conversion_utils,
  ../../../waku/waku_rln_relay/group_manager/static/group_manager

import
  stew/shims/net,
  chronos,
  libp2p/crypto/crypto,
  eth/keys,
  dnsdisc/builder

import
  std/tempfiles

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
    let rlnInstanceRes = createRlnInstance(tree_path = genTempPath("rln_tree", "group_manager_static"))
    require:
      rlnInstanceRes.isOk()

    let rlnInstance = rlnInstanceRes.get()
    let credentials = generateCredentials(rlnInstance, 10)

    let manager {.used.} = StaticGroupManager(rlnInstance: rlnInstance,
                                              groupSize: 10,
                                              membershipIndex: some(MembershipIndex(5)),
                                              groupKeys: credentials)

  asyncTest "should initialize successfully":
    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()

    await manager.init()
    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()
    check:
      manager.idCredentials.isSome()
      manager.groupKeys.len == 10
      manager.groupSize == 10
      manager.membershipIndex == some(MembershipIndex(5))
      manager.groupKeys[5] == manager.idCredentials.get()
      manager.latestIndex == 9
      merkleRootAfter.inHex() != merkleRootBefore.inHex()

  asyncTest "startGroupSync: should start group sync":
    await manager.init()
    require:
      manager.validRoots.len() == 1
      manager.rlnInstance.getMerkleRoot().get() == manager.validRoots[0]

    try:
      await manager.startGroupSync()
    except Exception, CatchableError:
      assert false, "exception raised when calling startGroupSync: " & getCurrentExceptionMsg()

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = StaticGroupManager(groupSize: 0,
                                     membershipIndex: some(MembershipIndex(0)),
                                     groupKeys: @[],
                                     rlnInstance: rlnInstance)
    try:
      await manager.startGroupSync()
    except ValueError:
      assert true
    except Exception, CatchableError:
      assert false, "exception raised when calling startGroupSync: " & getCurrentExceptionMsg()

  asyncTest "register: should guard against uninitialized state":
    let manager = StaticGroupManager(groupSize: 0,
                                     membershipIndex: some(MembershipIndex(0)),
                                     groupKeys: @[],
                                     rlnInstance: rlnInstance)

    let dummyCommitment = default(IDCommitment)

    try:
      when defined(rln_v2):
        await manager.register(RateCommitment(idCommitment: dummyCommitment, 
                                              userMessageLimit: DefaultUserMessageLimit))
      else:
        await manager.register(dummyCommitment)
    except ValueError:
      assert true
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

  asyncTest "register: should register successfully":
    await manager.init()
    try:
      await manager.startGroupSync()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment
    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
        merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()
    try:
      when defined(rln_v2):
        await manager.register(RateCommitment(idCommitment: idCommitment, 
                                              userMessageLimit: DefaultUserMessageLimit))
      else:
        await manager.register(idCommitment)
    except Exception, CatchableError:
        assert false, "exception raised: " & getCurrentExceptionMsg()
    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()
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
      when defined(rln_v2):
        require:
          registrations[0].rateCommitment == RateCommitment(idCommitment: idCommitment, userMessageLimit: DefaultUserMessageLimit)
      else:
        require:
          registrations[0].idCommitment == idCommitment
      callbackCalled = true
      fut.complete()

    try:
      manager.onRegister(callback)
      await manager.init()
      await manager.startGroupSync()
      when defined(rln_v2):
        await manager.register(RateCommitment(idCommitment: idCommitment, 
                                              userMessageLimit: DefaultUserMessageLimit))
      else:
        await manager.register(idCommitment)
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
    await manager.init()
    try:
      await manager.startGroupSync()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    let idSecretHash = credentials[0].idSecretHash
    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()
    try:
      await manager.withdraw(idSecretHash)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    let merkleRootAfterRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootAfterRes.isOk()
    let merkleRootAfter = merkleRootAfterRes.get()
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
      when defined(rln_v2):
        require:
          withdrawals[0].rateCommitment == RateCommitment(idCommitment: idCommitment, userMessageLimit: DefaultUserMessageLimit)
      else:
        require:
          withdrawals[0].idCommitment == idCommitment
      callbackCalled = true
      fut.complete()

    try:
      manager.onWithdraw(callback)
      await manager.init()
      await manager.startGroupSync()

      await manager.withdraw(idSecretHash)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut
    check:
      callbackCalled
