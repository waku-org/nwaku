import ../group_manager_base, ../../constants, ../../rln, std/sequtils

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
  when defined(rln_v2):
    g.userMessageLimit = some(DefaultUserMessageLimit)

  g.idCredentials = some(groupKeys[membershipIndex])
  # Seed the received commitments into the merkle tree
  when defined(rln_v2):
    let rateCommitments = groupKeys.mapIt(
      RateCommitment(
        idCommitment: it.idCommitment, userMessageLimit: g.userMessageLimit.get()
      )
    )
    let leaves = rateCommitments.toLeaves().valueOr:
      return err("Failed to convert rate commitments to leaves: " & $error)
    let membersInserted = g.rlnInstance.insertMembers(g.latestIndex, leaves)
  else:
    let idCommitments = groupKeys.mapIt(it.idCommitment)
    let membersInserted = g.rlnInstance.insertMembers(g.latestIndex, idCommitments)
    if not membersInserted:
      return err("Failed to insert members into the merkle tree")

  discard g.slideRootQueue()

  g.latestIndex += MembershipIndex(groupKeys.len - 1)

  g.initialized = true

  return ok()

method startGroupSync*(
    g: StaticGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  ?g.resultifiedInitGuard()
  # No-op
  return ok()

when defined(rln_v2):
  method register*(
      g: StaticGroupManager, rateCommitment: RateCommitment
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    await g.registerBatch(@[rateCommitment])

else:
  method register*(
      g: StaticGroupManager, idCommitment: IDCommitment
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    await g.registerBatch(@[idCommitment])

when defined(rln_v2):
  method registerBatch*(
      g: StaticGroupManager, rateCommitments: seq[RateCommitment]
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    let leavesRes = rateCommitments.toLeaves()
    if not leavesRes.isOk():
      raise newException(ValueError, "Failed to convert rate commitments to leaves")
    let leaves = cast[seq[seq[byte]]](leavesRes.get())

    let membersInserted = g.rlnInstance.insertMembers(g.latestIndex + 1, leaves)
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

    discard g.slideRootQueue()

    g.latestIndex += MembershipIndex(rateCommitments.len)

    return

else:
  method registerBatch*(
      g: StaticGroupManager, idCommitments: seq[IDCommitment]
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    let membersInserted = g.rlnInstance.insertMembers(g.latestIndex + 1, idCommitments)
    if not membersInserted:
      raise newException(ValueError, "Failed to insert members into the merkle tree")

    if g.registerCb.isSome():
      var memberSeq = newSeq[Membership]()
      for i in 0 ..< idCommitments.len:
        memberSeq.add(
          Membership(
            idCommitment: idCommitments[i],
            index: g.latestIndex + MembershipIndex(i) + 1,
          )
        )
      await g.registerCb.get()(memberSeq)

    discard g.slideRootQueue()

    g.latestIndex += MembershipIndex(idCommitments.len)

    return

when defined(rln_v2):
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
        )
        let memberRemoved = g.rlnInstance.removeMember(index)
        if not memberRemoved:
          raise newException(ValueError, "Failed to remove member from the merkle tree")

        if g.withdrawCb.isSome():
          let withdrawCb = g.withdrawCb.get()
          await withdrawCb(@[Membership(rateCommitment: rateCommitment, index: index)])

        return

else:
  method withdraw*(
      g: StaticGroupManager, idSecretHash: IdentitySecretHash
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    let groupKeys = g.groupKeys

    for i in 0 ..< groupKeys.len:
      if groupKeys[i].idSecretHash == idSecretHash:
        let idCommitment = groupKeys[i].idCommitment
        let index = MembershipIndex(i)
        let memberRemoved = g.rlnInstance.removeMember(index)
        if not memberRemoved:
          raise newException(ValueError, "Failed to remove member from the merkle tree")

        if g.withdrawCb.isSome():
          let withdrawCb = g.withdrawCb.get()
          await withdrawCb((@[Membership(idCommitment: idCommitment, index: index)]))

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
