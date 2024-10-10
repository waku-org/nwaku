{.push raises: [].}

import std/options, results, chronos, libp2p/stream/connection

import ../common/nimchronos, ../common/protobuf, ../waku_core, ./common, ./codec

#TODO add states for protocol negotiation

### Type State ###

type ClientSync* = object
  haveHashes: seq[WakuMessageHash]

type ServerSync* = object

# T is either ClientSync or ServerSync

type Reconciled*[T] = object
  sync: T
  negentropy: Negentropy
  connection: Connection
  frameSize: int
  payload*: SyncPayload

type Sent*[T] = object
  sync: T
  negentropy: Negentropy
  connection: Connection
  frameSize: int

type Received*[T] = object
  sync: T
  negentropy: Negentropy
  connection: Connection
  frameSize: int
  payload*: SyncPayload

type Completed*[T] = object
  sync: T
  negentropy: Negentropy
  connection: Connection
  haveHashes: seq[WakuMessageHash]

### State Transition ###

proc clientInitialize*(
    store: NegentropyStorage,
    conn: Connection,
    frameSize = DefaultMaxFrameSize,
    start = int64.low,
    `end` = int64.high,
): Result[Reconciled[ClientSync], string] =
  # let subrange = ?NegentropySubRangeStorage.new(store, uint64(start), uint64(`end`))

  # let negentropy = ?Negentropy.new(subrange, frameSize)

  # let negentropyPayload = ?negentropy.initiate()

  # let payload = SyncPayload(negentropy: seq[byte](negentropyPayload))

  # let sync = ClientSync()

  return ok(Reconciled[ClientSync]())

proc serverInitialize*(
    store: NegentropyStorage,
    conn: Connection,
    frameSize = DefaultMaxFrameSize,
    syncStart = int64.low,
    syncEnd = int64.high,
): Result[Sent[ServerSync], string] =
  return ok(Sent[ServerSync]())

proc send*[T](self: Reconciled[T]): Future[Result[Sent[T], string]] {.async.} =
  return ok(Sent[T]())

proc listenBack*[T](self: Sent[T]): Future[Result[Received[T], string]] {.async.} =
  return ok(Received[T]())

# Aliasing for readability
type ContinueOrCompleted[T] = Result[Reconciled[T], Completed[T]]
type Continue[T] = Reconciled[T]

proc clientReconcile*(
    self: Received[ClientSync], needHashes: var seq[WakuMessageHash]
): Result[ContinueOrCompleted[ClientSync], string] =
  let res = ContinueOrCompleted[ClientSync].ok(Continue[ClientSync]())

  return ok(res)

proc serverReconcile*(
    self: Received[ServerSync]
): Result[ContinueOrCompleted[ServerSync], string] =
  let res = ContinueOrCompleted[ServerSync].err(Completed[ServerSync]())

  return ok(res)

proc clientTerminate*(
    self: Completed[ClientSync]
): Future[Result[void, string]] {.async.} =
  return ok()

proc serverTerminate*(
    self: Completed[ServerSync]
): Future[seq[WakuMessageHash]] {.async.} =
  return self.haveHashes
