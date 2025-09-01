import ../group_manager_base

export group_manager_base

# Placeholder for future OffchainGroupManager re-implementation
type OffchainGroupManager* = ref object of GroupManager
  groupKeys*: seq[IdentityCredential]
  groupSize*: uint

template initializedGuard*(g: OffchainGroupManager): untyped =
  discard

proc resultifiedInitGuard(g: OffchainGroupManager): GroupManagerResult[void] =
  raise newException(CatchableError, "OffchainGroupManager's init is not implemented")

method init*(g: OffchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's init is not implemented")

method startGroupSync*(
    g: OffchainGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's startGroupSync is not implemented")

method register*(
    g: OffchainGroupManager, rateCommitment: RateCommitment
): Future[void] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's register is not implemented")

method registerBatch*(
    g: OffchainGroupManager, rateCommitments: seq[RawRateCommitment]
): Future[void] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's registerBatch is not implemented")

method withdraw*(
    g: OffchainGroupManager, idSecretHash: IdentitySecretHash
): Future[void] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's withdraw is not implemented")

method withdrawBatch*(
    g: OffchainGroupManager, idSecretHashes: seq[IdentitySecretHash]
): Future[void] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's withdrawBatch is not implemented")

method onRegister*(g: OffchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  raise newException(CatchableError, "OffchainGroupManager's onRegister is not implemented")

method onWithdraw*(g: OffchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  raise newException(CatchableError, "OffchainGroupManager's onWithdraw is not implemented")

method stop*(g: OffchainGroupManager): Future[void] {.async.} =
  raise newException(CatchableError, "OffchainGroupManager's stop is not implemented")

method isReady*(g: OffchainGroupManager): Future[bool] {.async.} =
  return false
