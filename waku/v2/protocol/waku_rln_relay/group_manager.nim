## This module defines a group manager interface. Implementations of
## GroupManager are used by the `WakuRlnRelay` protocol to obtain and access 
## rln membership group state
{.push raises: [Defect].}

import
  chronos,
  stew/results,
  rln_types

type
  GroupManagerResult*[T] = Result[T, string]
  GroupManager* = ref object of RootObj
  UpdateHandler* = proc(idComm: IDCommitment, index: MembershipIndex): GroupManagerResult[void] {.gcsafe, raises: [Defect].}
  RegistrationHandler* = proc(txHash: string): void {.gcsafe, closure, raises: [Defect].}

  

method setEventsHandlers*(gManager: GroupManager, memberInsertionHandler: UpdateHandler, memberDeletionHandler: UpdateHandler): GroupManagerResult[void] {.base.}  = discard
method setRegistrationHandler*(gManager: GroupManager, registrationHanlder: Option[RegistrationHandler]): GroupManagerResult[void] {.base.} = discard
method start*(gManager: GroupManager) {.base, async, gcsafe.}  = discard
method stop*(gManager: GroupManager): GroupManagerResult[void] {.base.}  = discard
method register*(gManager: GroupManager, idComm: IDCommitment): Future[GroupManagerResult[MembershipIndex]]  {.base, async, gcsafe.} = discard
