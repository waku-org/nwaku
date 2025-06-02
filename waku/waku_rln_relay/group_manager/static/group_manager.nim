import ../group_manager_base, ../../rln, std/sequtils, ../../constants

export group_manager_base

type StaticGroupManager* = ref object of GroupManager
  groupKeys*: seq[IdentityCredential]
  groupSize*: uint

template initializedGuard*(g: StaticGroupManager): untyped =
  if not g.initialized:
    raise newException(ValueError, "StaticGroupManager is not initialized")

proc resultifiedInitGuard(g: StaticGroupManager): GroupManagerResult[void] =
  try:
    initializedGuard(g)
    return ok()
  except CatchableError:
    return err("StaticGroupManager is not initialized")

method init*(g: StaticGroupManager): Future[GroupManagerResult[void]] {.async.} =
  let
    groupSize = g.groupSize
    groupKeys = g.groupKeys
    membershipIndex =
      if g.membershipIndex.isSome():
        g.membershipIndex.get()
      else:
        return err("membershipIndex is not set")

  if membershipIndex < MembershipIndex(0) or
      membershipIndex >= MembershipIndex(groupSize):
    return err(
      "Invalid membership index. Must be within 0 and " & $(groupSize - 1) & "but was " &
        $membershipIndex
    )
  g.userMessageLimit = some(DefaultUserMessageLimit)

  g.idCredentials = some(groupKeys[membershipIndex])

  g.latestIndex += MembershipIndex(groupKeys.len - 1)

  g.initialized = true

  return ok()

method startGroupSync*(
    g: StaticGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  ?g.resultifiedInitGuard()
  # No-op
  return ok()

method register*(
    g: StaticGroupManager, rateCommitment: RateCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let leaf = rateCommitment.toLeaf().get()

  await g.registerBatch(@[leaf])

method registerBatch*(
    g: StaticGroupManager, rateCommitments: seq[RawRateCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let membersInserted = g.rlnInstance.insertMembers(g.latestIndex + 1, rateCommitments)
  if not membersInserted:
    raise newException(ValueError, "Failed to insert members into the merkle tree")

  if g.registerCb.isSome():
    var memberSeq = newSeq[Membership]()
    for i in 0 ..< rateCommitments.len:
      memberSeq.add(
        Membership(
          rateCommitment: rateCommitments[i],
          index: g.latestIndex + MembershipIndex(i) + 1,
        )
      )
    await g.registerCb.get()(memberSeq)

  g.latestIndex += MembershipIndex(rateCommitments.len)
  return

method withdraw*(
    g: StaticGroupManager, idSecretHash: IdentitySecretHash
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let groupKeys = g.groupKeys

  for i in 0 ..< groupKeys.len:
    if groupKeys[i].idSecretHash == idSecretHash:
      let idCommitment = groupKeys[i].idCommitment
      let index = MembershipIndex(i)
      let rateCommitment = RateCommitment(
        idCommitment: idCommitment, userMessageLimit: g.userMessageLimit.get()
      ).toLeaf().valueOr:
        raise newException(ValueError, "Failed to parse rateCommitment")
      let memberRemoved = g.rlnInstance.removeMember(index)
      if not memberRemoved:
        raise newException(ValueError, "Failed to remove member from the merkle tree")

      if g.withdrawCb.isSome():
        let withdrawCb = g.withdrawCb.get()
        await withdrawCb(@[Membership(rateCommitment: rateCommitment, index: index)])

      return

method withdrawBatch*(
    g: StaticGroupManager, idSecretHashes: seq[IdentitySecretHash]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  # call withdraw on each idSecretHash
  for idSecretHash in idSecretHashes:
    await g.withdraw(idSecretHash)

method onRegister*(g: StaticGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: StaticGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

method stop*(g: StaticGroupManager): Future[void] {.async.} =
  initializedGuard(g)
  # No-op

method isReady*(g: StaticGroupManager): Future[bool] {.async.} =
  initializedGuard(g)
  return true
