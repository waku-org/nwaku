when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options, stew/results, chronos, libp2p/stream/connection

import
  ../common/nimchronos,
  ../common/protobuf,
  ../waku_core,
  ./raw_bindings,
  ./common,
  ./codec

#TODO add states for protocol negotiation

### Type State ###

type ClientSync* = object
  haveHashes: seq[WakuMessageHash]

type ServerSync* = object

type Reconciled*[T] = object
  sync: T
  negentropy: NegentropySubRange
  connection: Connection
  frameSize: int
  payload*: SyncPayload

type Sent*[T] = object
  sync: T
  negentropy: NegentropySubRange
  connection: Connection
  frameSize: int

type Received*[T] = object
  sync: T
  negentropy: NegentropySubRange
  connection: Connection
  frameSize: int
  payload*: SyncPayload

type Completed*[T] = object
  sync: T
  negentropy: NegentropySubRange
  connection: Connection
  haveHashes: seq[WakuMessageHash]

### State Transition ###

proc clientInitialize*(
    store: Storage,
    conn: Connection,
    frameSize = DefaultMaxFrameSize,
    start = int64.low,
    `end` = int64.high,
): Result[Reconciled[ClientSync], string] =
  let subrange = ?SubRange.new(store, uint64(start), uint64(`end`))

  let negentropy = ?NegentropySubrange.new(subrange, frameSize)

  let negentropyPayload = ?negentropy.initiate()

  let payload = SyncPayload(negentropy: seq[byte](negentropyPayload))

  let sync = ClientSync()

  return ok(
    Reconciled[ClientSync](
      sync: sync,
      negentropy: negentropy,
      connection: conn,
      frameSize: frameSize,
      payload: payload,
    )
  )

proc serverInitialize*(
    store: Storage,
    conn: Connection,
    frameSize = DefaultMaxFrameSize,
    start = int64.low,
    `end` = int64.high,
): Result[Sent[ServerSync], string] =
  let subrange = ?SubRange.new(store, uint64(start), uint64(`end`))

  let negentropy = ?NegentropySubrange.new(subrange, frameSize)

  let sync = ServerSync()

  return ok(
    Sent[ServerSync](
      sync: sync, negentropy: negentropy, connection: conn, frameSize: frameSize
    )
  )

proc send*[T](self: Reconciled[T]): Future[Result[Sent[T], string]] {.async.} =
  let writeRes = catch:
    await self.connection.writeLP(self.payload.encode().buffer)

  if writeRes.isErr():
    return err("send connection write error: " & writeRes.error.msg)

  return ok(
    Sent[T](
      sync: self.sync,
      negentropy: self.negentropy,
      connection: self.connection,
      frameSize: self.frameSize,
    )
  )

proc listenBack*[T](self: Sent[T]): Future[Result[Received[T], string]] {.async.} =
  let readRes = catch:
    await self.connection.readLp(-1)

  let buffer: seq[byte] =
    if readRes.isOk():
      readRes.get()
    else:
      return err("listenBack connection read error: " & readRes.error.msg)

  # can't otherwise the compiler complains
  #let payload = SyncPayload.decode(buffer).valueOr:
  #return err($error)

  let decodeRes = SyncPayload.decode(buffer)

  let payload =
    if decodeRes.isOk():
      decodeRes.get()
    else:
      let decodeError: ProtobufError = decodeRes.error
      let errMsg = $decodeError
      return err("listenBack decoding error: " & errMsg)

  return ok(
    Received[T](
      sync: self.sync,
      negentropy: self.negentropy,
      connection: self.connection,
      frameSize: self.frameSize,
      payload: payload,
    )
  )

proc clientReconcile*(
    self: Received[ClientSync], needHashes: var seq[WakuMessageHash]
): Result[Result[Reconciled[ClientSync], Completed[ClientSync]], string] =
  var haves = self.sync.haveHashes

  let responseOpt =
    ?self.negentropy.clientReconcile(
      NegentropyPayload(self.payload.negentropy), haves, needHashes
    )

  let sync = ClientSync(haveHashes: haves)

  let response = responseOpt.valueOr:
    let res = Result[Reconciled[ClientSync], Completed[ClientSync]].err(
      Completed[ClientSync](
        sync: sync, negentropy: self.negentropy, connection: self.connection
      )
    )

    return ok(res)

  let payload = SyncPayload(negentropy: seq[byte](response), hashes: haves)

  let res = Result[Reconciled[ClientSync], Completed[ClientSync]].ok(
    Reconciled[ClientSync](
      sync: sync,
      negentropy: self.negentropy,
      connection: self.connection,
      frameSize: self.frameSize,
      payload: payload,
    )
  )

  return ok(res)

proc serverReconcile*(
    self: Received[ServerSync]
): Result[Result[Reconciled[ServerSync], Completed[ServerSync]], string] =
  if self.payload.negentropy.len == 0:
    let res = Result[Reconciled[ServerSync], Completed[ServerSync]].err(
      Completed[ServerSync](
        sync: self.sync,
        negentropy: self.negentropy,
        connection: self.connection,
        haveHashes: self.payload.hashes,
      )
    )

    return ok(res)

  let response =
    ?self.negentropy.serverReconcile(NegentropyPayload(self.payload.negentropy))

  let payload = SyncPayload(negentropy: seq[byte](response))

  let res = Result[Reconciled[ServerSync], Completed[ServerSync]].ok(
    Reconciled[ServerSync](
      sync: self.sync,
      negentropy: self.negentropy,
      connection: self.connection,
      frameSize: self.frameSize,
      payload: payload,
    )
  )

  return ok(res)

proc clientTerminate*(
    self: Completed[ClientSync]
): Future[Result[void, string]] {.async.} =
  let payload = SyncPayload(hashes: self.sync.haveHashes)

  let writeRes = catch:
    await self.connection.writeLp(payload.encode().buffer)

  if writeRes.isErr():
    return err("clientTerminate connection write error: " & writeRes.error.msg)

  self.negentropy.delete()

  return ok()

proc serverTerminate*(
    self: Completed[ServerSync]
): Future[seq[WakuMessageHash]] {.async.} =
  self.negentropy.delete()

  return self.haveHashes
