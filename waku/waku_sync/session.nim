when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options, stew/results, chronicles, chronos, libp2p/stream/connection

import ../common/nimchronos, ../waku_core, ./raw_bindings, ./storage_manager

logScope:
  topics = "waku sync"

type SyncSessionType* = enum
  CLIENT = 1
  SERVER = 2

type SyncSessionState* = enum
  INIT = 1
  NEGENTROPY_SYNC = 2
  COMPLETE = 3

type SyncSession* = ref object
  sessType*: SyncSessionType
  curState*: SyncSessionState
  frameSize*: int
  rangeStart*: int64
  rangeEnd*: int64
  negentropy*: NegentropySubRange

#[
    Session State Machine
    1. negotiate sync params
    2. start negentropy sync
    3. find out local needhashes
    4. If client, share peer's needhashes to peer
]#

proc initializeNegentropy(
    self: SyncSession, storage: Storage, syncStartTime: int64, syncEndTime: int64
): Result[void, string] =
  #TODO Create a subrange
  let subrange = SubRange.new(storage, uint64(syncStartTime), uint64(syncEndTime)).valueOr:
    return err(error)
  let negentropy = NegentropySubrange.new(subrange, self.frameSize).valueOr:
    return err(error)

  self.negentropy = negentropy

  return ok()

proc HandleClientSession*(
    self: SyncSession, conn: Connection, storage: Storage
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  if self
  .initializeNegentropy(
    storage,
    timestampInSeconds(getNowInNanosecondTime()),
      # now , TODO: this needs to be tuned maybe consider 20 seconds jitter in network.
    int64.high, #timestampInSeconds(getNowInNanosecondTime()) - 60 * 60, # 1 hour
  )
  .isErr():
    return
  defer:
    self.negentropy.delete()

  let payload = self.negentropy.initiate().valueOr:
    return err(error)
  debug "Client sync session initialized", remotePeer = conn.peerId

  let writeRes = catch:
    await conn.writeLP(seq[byte](payload))

  trace "request sent to server", payload = toHex(seq[byte](payload))

  if writeRes.isErr():
    return err(writeRes.error.msg)

  var
    haveHashes: seq[WakuMessageHash] # Send it across to Server at the end of sync
    needHashes: seq[WakuMessageHash]

  while true:
    let readRes = catch:
      await conn.readLp(self.frameSize)

    let buffer: seq[byte] = readRes.valueOr:
      return err(error.msg)

    trace "Received Sync request from peer", payload = toHex(buffer)

    let request = NegentropyPayload(buffer)

    let responseOpt = self.negentropy.clientReconcile(request, haveHashes, needHashes).valueOr:
      return err(error)

    let response = responseOpt.valueOr:
      debug "Closing connection, client sync session is done"
      await conn.close()
      break

    trace "Sending Sync response to peer", payload = toHex(seq[byte](response))

    let writeRes = catch:
      await conn.writeLP(seq[byte](response))

    if writeRes.isErr():
      return err(writeRes.error.msg)

  return ok(needHashes)

proc HandleServerSession*(
    self: SyncSession, conn: Connection, storage: Storage
) {.async, gcsafe.} =
  #TODO: Pass sync time based on data in request??
  #TODO: Return error rather than closing stream abruptly?
  if self
  .initializeNegentropy(
    storage,
    timestampInSeconds(getNowInNanosecondTime()),
    int64.high, #timestampInSeconds(getNowInNanosecondTime()) - 60 * 60,
  )
  .isErr():
    return
  defer:
    self.negentropy.delete()

  while not conn.isClosed:
    let requestRes = catch:
      await conn.readLp(self.frameSize)

    let buffer = requestRes.valueOr:
      if error.name != $LPStreamRemoteClosedError or error.name != $LPStreamClosedError:
        debug "Connection reading error", error = error.msg

      break

    #TODO: Once we receive needHashes or endOfSync, we should close this stream.
    let request = NegentropyPayload(buffer)

    let response = self.negentropy.serverReconcile(request).valueOr:
      error "Reconciliation error", error = error
      break

    let writeRes = catch:
      await conn.writeLP(seq[byte](response))

    if writeRes.isErr():
      error "Connection write error", error = writeRes.error.msg
      break

  return
