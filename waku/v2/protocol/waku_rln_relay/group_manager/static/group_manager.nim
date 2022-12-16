import
    ../group_manager_base,
    ../../ffi,
    std/sequtils

export
  group_manager_base

type
    StaticGroupManagerConfig* = object
      groupKeys*: seq[IdentityCredential]
      groupSize*: uint
      membershipIndex*: MembershipIndex

    StaticGroupManager* = ref object of GroupManager[StaticGroupManagerConfig]

template initializedGuard*(g: StaticGroupManager): untyped =
  if not g.initialized:
      raise newException(ValueError, "StaticGroupManager is not initialized")

proc init*(g: StaticGroupManager): Future[void] {.async,gcsafe.} =
  let
    groupSize = g.config.groupSize
    groupKeys = g.config.groupKeys
    membershipIndex = g.config.membershipIndex

  if membershipIndex < MembershipIndex(0) or membershipIndex >= MembershipIndex(groupSize):
    raise newException(ValueError, "Invalid membership index. Must be within 0 and " & $(groupSize - 1) & "but was " & $membershipIndex)
  g.idCredentials = some(groupKeys[membershipIndex])

  # Seed the received commitments into the merkle tree
  let idCommitments = groupKeys.mapIt(it.idCommitment)
  let membersInserted = g.rlnInstance.insertMembers(g.latestIndex, idCommitments)
  if not membersInserted:
    raise newException(ValueError, "Failed to insert members into the merkle tree")

  g.latestIndex += MembershipIndex(idCommitments.len() - 1)

  g.initialized = true

  return

proc startGroupSync*(g: StaticGroupManager): Future[void] =
  initializedGuard(g)
  var retFuture = newFuture[void]("StaticGroupManager.sta rtGroupSync")
  # No-op
  retFuture.complete()
  return retFuture

proc register*(g: StaticGroupManager, idCommitment: IDCommitment): Future[void] {.async.} =
  initializedGuard(g)

  let memberInserted = g.rlnInstance.insertMember(idCommitment)
  if not memberInserted:
    raise newException(ValueError, "Failed to insert member into the merkle tree")

  g.latestIndex += 1

  if g.registerCb.isSome():
    await g.registerCb.get()(@[Membership(idCommitment: idCommitment, index: g.latestIndex)])
  return

proc registerBatch*(g: StaticGroupManager, idCommitments: seq[IDCommitment]): Future[void] {.async.} =
  initializedGuard(g)

  let membersInserted = g.rlnInstance.insertMembers(g.latestIndex + 1, idCommitments)
  if not membersInserted:
    raise newException(ValueError, "Failed to insert members into the merkle tree")

  g.latestIndex += MembershipIndex(idCommitments.len() - 1)

  if g.registerCb.isSome():
    var memberSeq = newSeq[Membership]()
    for i in 0..<idCommitments.len():
      memberSeq.add(Membership(idCommitment: idCommitments[i], index: g.latestIndex - MembershipIndex(i)))
    await g.registerCb.get()(memberSeq)

  return

proc withdraw*(g: StaticGroupManager, idSecretHash: IdentitySecretHash): Future[void] {.async.} =
  initializedGuard(g)

  let groupKeys = g.config.groupKeys

  for i in 0..<groupKeys.len():
    if groupKeys[i].idSecretHash == idSecretHash:
        let idCommitment = groupKeys[i].idCommitment
        let index = MembershipIndex(i)
        let memberRemoved = g.rlnInstance.removeMember(index)
        if not memberRemoved:
          raise newException(ValueError, "Failed to remove member from the merkle tree")

        if g.withdrawCb.isSome():
          await g.withdrawCb.get()(@[Membership(idCommitment: idCommitment, index: index)])

        return


proc withdrawBatch*(g: StaticGroupManager, idSecretHashes: seq[IdentitySecretHash]): Future[void] {.async.} =
  initializedGuard(g)

  # call withdraw on each idSecretHash
  for idSecretHash in idSecretHashes:
      await g.withdraw(idSecretHash)

proc onRegister*(g: StaticGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

proc onWithdraw*(g: StaticGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)
