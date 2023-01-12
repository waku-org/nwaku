import
  ../protocol_types
import
  options,
  chronos,
  stew/results

export
  options,
  chronos,
  results,
  protocol_types

# This module contains the GroupManager interface
# The GroupManager is responsible for managing the group state
# It should be used to register new members, and withdraw existing members
# It should also be used to sync the group state with the rest of the group members

type Membership* = object
  idCommitment*: IDCommitment
  index*: MembershipIndex

type OnRegisterCallback* = proc (registrations: seq[Membership]): Future[void] {.gcsafe.}
type OnWithdrawCallback* = proc (withdrawals: seq[Membership]): Future[void] {.gcsafe.}

type GroupManagerResult*[T] = Result[T, string]

type
  GroupManager*[Config] = ref object of RootObj
    idCredentials*: Option[IdentityCredential]
    registerCb*: Option[OnRegisterCallback]
    withdrawCb*: Option[OnWithdrawCallback]
    config*: Config
    rlnInstance*: ptr RLN
    initialized*: bool
    latestIndex*: MembershipIndex

# This proc is used to initialize the group manager
# Any initialization logic should be implemented here
method init*(g: GroupManager): Future[void] {.base,gcsafe.} =
  return err("init proc for " & $g.kind & " is not implemented yet")

# This proc is used to start the group sync process
# It should be used to sync the group state with the rest of the group members
method startGroupSync*(g: GroupManager): Future[void] {.base,gcsafe.} =
  return err("startGroupSync proc for " & $g.kind & " is not implemented yet")

# This proc is used to register a new identity commitment into the merkle tree
# The user may or may not have the identity secret to this commitment
# It should be used when detecting new members in the group, and syncing the group state
method register*(g: GroupManager, idCommitment: IDCommitment): Future[void] {.base,gcsafe.} =
  return err("register proc for " & $g.kind & " is not implemented yet")

# This proc is used to register a new identity commitment into the merkle tree
# The user should have the identity secret to this commitment
# It should be used when the user wants to join the group
method register*(g: GroupManager, credentials: IdentityCredential): Future[void] {.base,gcsafe.} =
  return err("register proc for " & $g.kind & " is not implemented yet")

# This proc is used to register a batch of new identity commitments into the merkle tree
# The user may or may not have the identity secret to these commitments
# It should be used when detecting a batch of new members in the group, and syncing the group state
method registerBatch*(g: GroupManager, idCommitments: seq[IDCommitment]): Future[void] {.base,gcsafe.} =
  return err("registerBatch proc for " & $g.kind & " is not implemented yet")

# This proc is used to set a callback that will be called when a new identity commitment is registered
# The callback may be called multiple times, and should be used to for any post processing
method onRegister*(g: GroupManager, cb: OnRegisterCallback) {.base,gcsafe.} =
  g.registerCb = some(cb)

# This proc is used to withdraw/remove an identity commitment from the merkle tree
# The user should have the identity secret hash to this commitment, by either deriving it, or owning it
method withdraw*(g: GroupManager, identitySecretHash: IdentitySecretHash): Future[void] {.base,gcsafe.} =
  return err("withdraw proc for " & $g.kind & " is not implemented yet")

# This proc is used to withdraw/remove a batch of identity commitments from the merkle tree
# The user should have the identity secret hash to these commitments, by either deriving them, or owning them
method withdrawBatch*(g: GroupManager, identitySecretHashes: seq[IdentitySecretHash]): Future[void] {.base,gcsafe.} =
  return err("withdrawBatch proc for " & $g.kind & " is not implemented yet")

# This proc is used to set a callback that will be called when an identity commitment is withdrawn
# The callback may be called multiple times, and should be used to for any post processing
method onWithdraw*(g: GroupManager, cb: OnWithdrawCallback) {.base,gcsafe.} =
  g.withdrawCb = some(cb)
