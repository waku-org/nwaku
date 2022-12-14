# This module contains the GroupManagerBase interface
# The GroupManager is responsible for managing the group state
# It should be used to register new members, and withdraw existing members
# It should also be used to sync the group state with the rest of the group members

type OnRegisterCallback* = proc (registrations: seq[(IDCommitment, MembershipIndex)]) {.async, gcsafe.}
type OnWithdrawCallback* = proc (withdrawals: seq[(IDCommitment, MembershipIndex)]) {.async, gcsafe.}

type 
    GroupManagerBase*[Config] = ref object of RootObj
        idCredentials*: Option[IdentityCredentials]
        onRegisterCb: Option[OnRegisterCallback]
        onWithdrawCb: Option[OnWithdrawCallback]
        config*: Config
        rlnInstance: ptr RLN
        initialized*: bool

# This method is used to initialize the group manager
# Any initialization logic should be implemented here
method init*(g: GroupManagerBase): Result[void] {.async,base.} =
    return err("init method for " & $g.kind & " is not implemented yet")

# This method is used to start the group sync process
# It should be used to sync the group state with the rest of the group members
method startGroupSync*(g: GroupManagerBase): Result[void] {.async,base.} =
    return err("startGroupSync method for " & $g.kind & " is not implemented yet")

# This method is used to register a new identity commitment into the merkle tree
# The user may or may not have the identity secret to this commitment
# It should be used when detecting new members in the group, and syncing the group state
method register*(g: GroupManagerBase, idCommitment: IDCommitment): Result[void] {.async,base.} = 
    return err("register method for " & $g.kind & " is not implemented yet")

# This method is used to register a new identity commitment into the merkle tree
# The user should have the identity secret to this commitment
# It should be used when the user wants to join the group
method register*(g: GroupManagerBase, credentials: IdentityCredentials): Result[void] {.async,base.} = 
    return err("register method for " & $g.kind & " is not implemented yet")

# This method is used to register a batch of new identity commitments into the merkle tree
# The user may or may not have the identity secret to these commitments
# It should be used when detecting a batch of new members in the group, and syncing the group state
method registerBatch*(g: GroupManagerBase, idCommitments: seq[IDCommitment]): Result[void] {.async,base.} = 
    return err("registerBatch method for " & $g.kind & " is not implemented yet")

# This method is used to set a callback that will be called when a new identity commitment is registered
# The callback may be called multiple times, and should be used to for any post processing
method onRegister*(g: GroupManagerBase, cb: OnRegisterCallback): Result[void] {.base.} = 
    g.onRegisterCb = some(cb)
    return ok()

# This method is used to withdraw/remove an identity commitment from the merkle tree
# The user should have the identity secret hash to this commitment, by either deriving it, or owning it
method withdraw*(g: GroupManagerBase, identitySecretHash: IdentitySecretHash): Result[void] {.async,base.} = 
    return err("withdraw method for " & $g.kind & " is not implemented yet")

# This method is used to withdraw/remove a batch of identity commitments from the merkle tree
# The user should have the identity secret hash to these commitments, by either deriving them, or owning them
method withdrawBatch*(g: GroupManagerBase, identitySecretHashes: seq[IdentitySecretHash]): Result[void] {.async,base.} =
    return err("withdrawBatch method for " & $g.kind & " is not implemented yet")

# This method is used to set a callback that will be called when an identity commitment is withdrawn
# The callback may be called multiple times, and should be used to for any post processing
method onWithdraw*(g: GroupManagerBase, cb: OnRegisterCallback): Result[void] {.base.} =
    g.onWithdrawCb = some(cb)
    return ok()
