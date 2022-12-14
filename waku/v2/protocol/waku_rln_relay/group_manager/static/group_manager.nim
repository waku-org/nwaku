import 
    ../group_manager_base

type
    StaticGroupManagerConfig* = object
        rawGroupKeys*: seq[string]
        groupKeys*: Option[seq[IdentityCredentials]]
        groupSize*: uint
        membershipIndex*: MembershipIndex

    StaticGroupManager* = ref object of GroupManagerBase[StaticGroupManagerConfig]

template initializedGuard*(g: StaticGroupManager): untyped =
    if not g.initialized:
        return err("StaticGroupManager is not initialized")

method init*(g: StaticGroupManager): Result[void] =
    let
        rawGroupKeys = g.config.rawGroupKeys
        groupSize = g.config.groupSize
        membershipIndex = g.config.membershipIndex
    
    if membershipIndex < MembershipIndex(0) or membershipIndex >= MembershipIndex(groupSize):
        return err("Invalid membership index. Must be within 0 and " & $(groupSize - 1) & "but was " & $membershipIndex)

    let parsedGroupKeys = rawGroupKeys.map(parseGroupKey)
    if parsedGroupKeys.anyIt(it.isErr):
        return err("Invalid group key: " & $parsedGroupKeys.findIt(it.isErr).getErr())

    g.config.groupKeys = some(parsedGroupKeys.mapIt(it.get()))
    g.idCredentials = g.config.groupKeys[membershipIndex]

    # Seed the received commitments into the merkle tree
    let membersInserted = g.rlnInstance.insertMembers(g.config.groupKeys.mapIt(it.idCommitment))
    if not membersInserted:
        return err("Failed to insert members into the merkle tree")

    g.initialized = true
    return ok()

method startGroupSync*(g: StaticGroupManager): Result[void] {.async.} =
    initializedGuard(g)
    # No-op
    return ok()
    
method register*(g: StaticGroupManager, idCommitment: IDCommitment): Result[void] {.async.} =
    initializedGuard(g)

    let memberInserted = g.rlnInstance.insertMember(idCommitment)
    if not memberInserted:
        return err("Failed to insert member into the merkle tree")

    if g.onRegisterCb.isSome():
        await g.onRegisterCb.get()(@[idCommitment])

    return ok()


method registerBatch*(g: StaticGroupManager, idCommitments: seq[IDCommitment]): Result[void] {.async.} =
    initializedGuard(g)

    let membersInserted = g.rlnInstance.insertMembers(idCommitments)
    if not membersInserted:
        return err("Failed to insert members into the merkle tree")

    if g.onRegisterCb.isSome():
        await g.onRegisterCb.get()(idCommitments)
    
    return ok()

method withdraw*(g: StaticGroupManager, idSecretHash: IdentitySecretHash): Result[void] {.async.} =
    initializedGuard(g)

    let groupKeys = g.config.groupKeys.get()
    let idCommitment = groupKeys.findIt(it.idSecretHash == idSecretHash).get().idCommitment
    let memberRemoved = g.rlnInstance.removeMember(idCommitment)
    if not memberRemoved:
        return err("Failed to remove member from the merkle tree")

    if g.onWithdrawCb.isSome():
        await g.onWithdrawCb.get()(@[idCommitment])

    return ok()

method withdrawBatch*(g: StaticGroupManager, idSecretHashes: seq[IdentitySecretHash]): Result[void] {.async.} =
    initializedGuard(g)

    let groupKeys = g.config.groupKeys.get()
    let identityCommitments = idSecretHashes.map(groupKeys.findIt(it.idSecretHash == idSecretHash).get().idCommitment)
    let membersRemoved = g.rlnInstance.removeMembers(idCommitments)
    if not membersRemoved:
        return err("Failed to remove members from the merkle tree")

    if g.onWithdrawCb.isSome():
        await g.onWithdrawCb.get()(idCommitments)

    return ok()