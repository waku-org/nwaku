{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  testutils/unittests,
  stew/results,
  options,
  ../../../waku/v2/protocol/waku_rln_relay/protocol_types,
  ../../../waku/v2/protocol/waku_rln_relay/rln,
  ../../../waku/v2/protocol/waku_rln_relay/conversion_utils,
  ../../../waku/v2/protocol/waku_rln_relay/group_manager/static/group_manager

import
  stew/shims/net,
  chronos,
  libp2p/crypto/crypto,
  eth/keys,
  discovery/dnsdisc/builder

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
    let rlnInstanceRes = createRlnInstance()
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
    await manager.startGroupSync()

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = StaticGroupManager(groupSize: 0,
                                     membershipIndex: some(MembershipIndex(0)),
                                     groupKeys: @[],
                                     rlnInstance: rlnInstance)

    expect(ValueError):
      await manager.startGroupSync()

  asyncTest "register: should guard against uninitialized state":
    let manager = StaticGroupManager(groupSize: 0,
                                     membershipIndex: some(MembershipIndex(0)),
                                     groupKeys: @[],
                                     rlnInstance: rlnInstance)

    let dummyCommitment = default(IDCommitment)

    expect(ValueError):
      await manager.register(dummyCommitment)

  asyncTest "register: should register successfully":
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
      manager.latestIndex == 10

  asyncTest "register: callback is called":
    var callbackCalled = false
    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      require:
        registrations.len == 1
        registrations[0].idCommitment == idCommitment
        registrations[0].index == 10
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
    let idSecretHash = credentials[0].idSecretHash

    expect(ValueError):
      await manager.withdraw(idSecretHash)

  asyncTest "withdraw: should withdraw successfully":
    await manager.init()
    await manager.startGroupSync()

    let idSecretHash = credentials[0].idSecretHash
    let merkleRootBeforeRes = manager.rlnInstance.getMerkleRoot()
    require:
      merkleRootBeforeRes.isOk()
    let merkleRootBefore = merkleRootBeforeRes.get()
    await manager.withdraw(idSecretHash)
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
        withdrawals[0].idCommitment == idCommitment
        withdrawals[0].index == 0
      callbackCalled = true
      fut.complete()

    manager.onWithdraw(callback)
    await manager.init()
    await manager.startGroupSync()

    await manager.withdraw(idSecretHash)

    await fut
    check:
      callbackCalled
