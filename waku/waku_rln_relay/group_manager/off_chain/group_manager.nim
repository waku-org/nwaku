import ../group_manager_base

export group_manager_base

# Placeholder for future OffchainGroupManager re-implementation
type OffchainGroupManager* = ref object of GroupManager
  groupKeys*: seq[IdentityCredential]
  groupSize*: uint

template initializedGuard*(g: OffchainGroupManager): untyped =
  discard

proc resultifiedInitGuard(g: OffchainGroupManager): GroupManagerResult[void] =
  return err("OffchainGroupManager is not implemented")

method init*(g: OffchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  discard

method startGroupSync*(
    g: OffchainGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  discard

method register*(
    g: OffchainGroupManager, rateCommitment: RateCommitment
): Future[void] {.async.} =
  discard

method registerBatch*(
    g: OffchainGroupManager, rateCommitments: seq[RawRateCommitment]
): Future[void] {.async.} =
  discard

method withdraw*(
    g: OffchainGroupManager, idSecretHash: IdentitySecretHash
): Future[void] {.async.} =
  discard

method withdrawBatch*(
    g: OffchainGroupManager, idSecretHashes: seq[IdentitySecretHash]
): Future[void] {.async.} =
  discard

method onRegister*(g: OffchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  discard

method onWithdraw*(g: OffchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  discard

method stop*(g: OffchainGroupManager): Future[void] {.async.} =
  discard

method isReady*(g: OffchainGroupManager): Future[bool] {.async.} =
  return false
