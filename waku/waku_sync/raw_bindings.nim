when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

import std/[strutils], chronicles, std/options, stew/byteutils, confutils, results
import ../waku_core/message

const negentropyPath =
  currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & ".." & DirSep & ".." & DirSep &
  "vendor" & DirSep & "negentropy" & DirSep & "cpp" & DirSep

{.link: negentropyPath & "libnegentropy.so".}

const NEGENTROPY_HEADER = negentropyPath & "negentropy_wrapper.h"

logScope:
  topics = "waku sync"

type Buffer = object
  len*: uint64
  `ptr`*: ptr uint8

type BindingResult = object
  output: Buffer
  have_ids_len: uint
  need_ids_len: uint
  have_ids: ptr Buffer
  need_ids: ptr Buffer
  error: cstring

proc toWakuMessageHash(buffer: Buffer): WakuMessageHash =
  assert buffer.len == 32

  var hash: WakuMessageHash

  copyMem(hash[0].addr, buffer.ptr, 32)

  return hash

proc toBuffer(x: openArray[byte]): Buffer =
  ## converts the input to a Buffer object
  ## the Buffer object is used to communicate data with the rln lib
  var temp = @x
  let baseAddr = cast[pointer](x)
  let output = Buffer(`ptr`: cast[ptr uint8](baseAddr), len: uint64(temp.len))
  return output

proc bufferToBytes(buffer: ptr Buffer, len: Option[uint64] = none(uint64)): seq[byte] =
  var bufLen: uint64
  if isNone(len):
    bufLen = buffer.len
  else:
    bufLen = len.get()
  if bufLen == 0:
    return @[]
  trace "length of buffer is", len = bufLen
  let bytes = newSeq[byte](bufLen)
  copyMem(bytes[0].unsafeAddr, buffer.ptr, bufLen)
  return bytes

proc toBufferSeq(buffLen: uint, buffPtr: ptr Buffer): seq[Buffer] =
  var uncheckedArr = cast[ptr UncheckedArray[Buffer]](buffPtr)
  var mySequence = newSeq[Buffer](buffLen)
  for i in 0 .. buffLen - 1:
    mySequence[i] = uncheckedArr[i]
  return mySequence

### Storage ###

type NegentropyStorage* = distinct pointer

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L27
proc storage_init(
  db_path: cstring, name: cstring
): NegentropyStorage {.header: NEGENTROPY_HEADER, importc: "storage_new".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L41
proc raw_insert(
  storage: NegentropyStorage, timestamp: uint64, id: ptr Buffer
): bool {.header: NEGENTROPY_HEADER, importc: "storage_insert".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L43
proc raw_erase(
  storage: NegentropyStorage, timestamp: uint64, id: ptr Buffer
): bool {.header: NEGENTROPY_HEADER, importc: "storage_erase".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L29
proc free(
  storage: NegentropyStorage
) {.header: NEGENTROPY_HEADER, importc: "storage_delete".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L31
proc size(
  storage: NegentropyStorage
): cint {.header: NEGENTROPY_HEADER, importc: "storage_size".}

### Negentropy ###

type RawNegentropy* = distinct pointer

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L33
proc constructNegentropy(
  storage: NegentropyStorage, frameSizeLimit: uint64
): RawNegentropy {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L37
proc raw_initiate(
  negentropy: RawNegentropy, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L39
proc raw_setInitiator(
  negentropy: RawNegentropy
) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L45
proc raw_reconcile(
  negentropy: RawNegentropy, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L51
proc raw_reconcile_with_ids(
  negentropy: RawNegentropy, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids_no_cbk".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L35
proc free(
  negentropy: RawNegentropy
) {.header: NEGENTROPY_HEADER, importc: "negentropy_delete".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L53
proc free_result(
  r: ptr BindingResult
) {.header: NEGENTROPY_HEADER, importc: "free_result".}

### SubRange ###

type NegentropySubRangeStorage* = distinct pointer

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L57
proc subrange_init(
  storage: NegentropyStorage, startTimestamp: uint64, endTimestamp: uint64
): NegentropySubRangeStorage {.header: NEGENTROPY_HEADER, importc: "subrange_new".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L59
proc free(
  subrange: NegentropySubRangeStorage
) {.header: NEGENTROPY_HEADER, importc: "subrange_delete".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L31
proc size(
  subrange: NegentropySubRangeStorage
): cint {.header: NEGENTROPY_HEADER, importc: "subrange_size".}

### Negentropy with NegentropySubRangeStorage ###

type RawNegentropySubRange = distinct pointer

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L61
proc constructNegentropyWithSubRange(
  subrange: NegentropySubRangeStorage, frameSizeLimit: uint64
): RawNegentropySubRange {.
  header: NEGENTROPY_HEADER, importc: "negentropy_subrange_new"
.}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L65
proc raw_initiate_subrange(
  negentropy: RawNegentropySubRange, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "negentropy_subrange_initiate".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L67
proc raw_reconcile_subrange(
  negentropy: RawNegentropySubRange, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile_subrange".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L69
proc raw_reconcile_with_ids_subrange(
  negentropy: RawNegentropySubRange, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids_subrange_no_cbk".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L63
proc free(
  negentropy: RawNegentropySubRange
) {.header: NEGENTROPY_HEADER, importc: "negentropy_subrange_delete".}

### Wrappings ###

### Storage ###

proc `==`*(a: NegentropyStorage, b: pointer): bool {.borrow.}

proc new*(T: type NegentropyStorage): Result[T, string] =
  #TODO db name and path
  let storage = storage_init("", "")

  #[ TODO: Uncomment once we move to lmdb   
  if storage == nil:
    return err("storage initialization failed") ]#
  return ok(storage)

proc delete*(storage: NegentropyStorage) =
  storage.free()

proc erase*(
    storage: NegentropyStorage, id: int64, hash: WakuMessageHash
): Result[void, string] =
  var buffer = toBuffer(hash)
  var bufPtr = addr(buffer)
  let res = raw_erase(storage, uint64(id), bufPtr)

  #TODO error handling once we move to lmdb

  if res:
    return ok()
  else:
    return err("erase error")

proc insert*(
    storage: NegentropyStorage, id: int64, hash: WakuMessageHash
): Result[void, string] =
  var buffer = toBuffer(hash)
  var bufPtr = addr(buffer)
  let res = raw_insert(storage, uint64(id), bufPtr)

  #TODO error handling once we move to lmdb

  if res:
    return ok()
  else:
    return err("insert error")

proc len*(storage: NegentropyStorage): int =
  int(storage.size)

### SubRange ###

proc `==`*(a: NegentropySubRangeStorage, b: pointer): bool {.borrow.}

proc new*(
    T: type NegentropySubRangeStorage,
    storage: NegentropyStorage,
    startTime: uint64 = uint64.low,
    endTime: uint64 = uint64.high,
): Result[T, string] =
  let subrange = subrange_init(storage, startTime, endTime)

  #[ TODO: Uncomment once we move to lmdb   
  if storage == nil:
    return err("storage initialization failed") ]#
  return ok(subrange)

proc delete*(subrange: NegentropySubRangeStorage) =
  subrange.free()

proc len*(subrange: NegentropySubRangeStorage): int =
  int(subrange.size)

### Interface ###

type
  Negentropy* = ref object of RootObj

  NegentropyWithSubRange = ref object of Negentropy
    inner: RawNegentropySubRange

  NegentropyWithStorage = ref object of Negentropy
    inner: RawNegentropy

  NegentropyPayload* = distinct seq[byte]

method delete*(self: Negentropy) {.base, gcsafe.} =
  discard

method initiate*(self: Negentropy): Result[NegentropyPayload, string] {.base.} =
  discard

method serverReconcile*(
    self: Negentropy, query: NegentropyPayload
): Result[NegentropyPayload, string] {.base.} =
  discard

method clientReconcile*(
    self: Negentropy,
    query: NegentropyPayload,
    haves: var seq[WakuMessageHash],
    needs: var seq[WakuMessageHash],
): Result[Option[NegentropyPayload], string] {.base.} =
  discard

### Impl. ###

proc new*(
    T: type Negentropy,
    storage: NegentropyStorage | NegentropySubRangeStorage,
    frameSizeLimit: int,
): Result[T, string] =
  if storage is NegentropyStorage:
    let raw_negentropy =
      constructNegentropy(NegentropyStorage(storage), uint64(frameSizeLimit))

    let negentropy = NegentropyWithStorage(inner: raw_negentropy)

    return ok(negentropy)
  elif storage is NegentropySubRangeStorage:
    let raw_negentropy = constructNegentropyWithSubRange(
      NegentropySubRangeStorage(storage), uint64(frameSizeLimit)
    )

    let negentropy = NegentropyWithSubRange(inner: raw_negentropy)

    return ok(negentropy)

method delete*(self: NegentropyWithSubRange) =
  self.inner.free()

method initiate*(self: NegentropyWithSubRange): Result[NegentropyPayload, string] =
  ## Client inititate a sync session with a server by sending a payload 
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = self.inner.raw_initiate_subrange(myResultPtr)
  if ret < 0 or myResultPtr == nil:
    error "negentropy initiate failed with code ", code = ret
    return err("negentropy already initiated!")
  let bytes: seq[byte] = bufferToBytes(addr(myResultPtr.output))
  free_result(myResultPtr)
  trace "received return from initiate", len = myResultPtr.output.len

  return ok(NegentropyPayload(bytes))

method serverReconcile*(
    self: NegentropyWithSubRange, query: NegentropyPayload
): Result[NegentropyPayload, string] =
  ## Server response to a negentropy payload.
  ## Always return an answer.

  let queryBuf = toBuffer(seq[byte](query))
  var queryBufPtr = queryBuf.unsafeAddr #TODO: Figure out why addr(buffer) throws error
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = self.inner.raw_reconcile_subrange(queryBufPtr, myResultPtr)
  if ret < 0:
    error "raw_reconcile failed with code ", code = ret
    return err($myResultPtr.error)
  trace "received return from raw_reconcile", len = myResultPtr.output.len

  let outputBytes: seq[byte] = bufferToBytes(addr(myResultPtr.output))
  trace "outputBytes len", len = outputBytes.len
  free_result(myResultPtr)

  return ok(NegentropyPayload(outputBytes))

method clientReconcile*(
    self: NegentropyWithSubRange,
    query: NegentropyPayload,
    haves: var seq[WakuMessageHash],
    needs: var seq[WakuMessageHash],
): Result[Option[NegentropyPayload], string] =
  ## Client response to a negentropy payload.
  ## May return an answer, if not the sync session done.

  let cQuery = toBuffer(seq[byte](query))

  var myResult {.noinit.}: BindingResult = BindingResult()
  myResult.have_ids_len = 0
  myResult.need_ids_len = 0
  var myResultPtr = addr myResult

  let ret = self.inner.raw_reconcile_with_ids_subrange(cQuery.unsafeAddr, myResultPtr)
  if ret < 0:
    error "raw_reconcile failed with code ", code = ret
    return err($myResultPtr.error)

  let output = bufferToBytes(addr myResult.output)

  var
    have_hashes: seq[Buffer]
    need_hashes: seq[Buffer]

  if myResult.have_ids_len > 0:
    have_hashes = toBufferSeq(myResult.have_ids_len, myResult.have_ids)
  if myResult.need_ids_len > 0:
    need_hashes = toBufferSeq(myResult.need_ids_len, myResult.need_ids)

  trace "have and need hashes ",
    have_count = have_hashes.len, need_count = need_hashes.len

  for i in 0 .. have_hashes.len - 1:
    var hash = toWakuMessageHash(have_hashes[i])
    trace "have hashes ", index = i, msg_hash = hash.to0xHex()
    haves.add(hash)

  for i in 0 .. need_hashes.len - 1:
    var hash = toWakuMessageHash(need_hashes[i])
    trace "need hashes ", index = i, msg_hash = hash.to0xHex()
    needs.add(hash)

  trace "return ", output = output, len = output.len

  free_result(myResultPtr)

  if output.len < 1:
    return ok(none(NegentropyPayload))

  return ok(some(NegentropyPayload(output)))

method delete*(self: NegentropyWithStorage) =
  self.inner.free()

method initiate*(self: NegentropyWithStorage): Result[NegentropyPayload, string] =
  ## Client inititate a sync session with a server by sending a payload 
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = self.inner.raw_initiate(myResultPtr)
  if ret < 0 or myResultPtr == nil:
    error "negentropy initiate failed with code ", code = ret
    return err("negentropy already initiated!")
  let bytes: seq[byte] = bufferToBytes(addr(myResultPtr.output))
  free_result(myResultPtr)
  trace "received return from initiate", len = myResultPtr.output.len

  return ok(NegentropyPayload(bytes))

method serverReconcile*(
    self: NegentropyWithStorage, query: NegentropyPayload
): Result[NegentropyPayload, string] =
  ## Server response to a negentropy payload.
  ## Always return an answer.

  let queryBuf = toBuffer(seq[byte](query))
  var queryBufPtr = queryBuf.unsafeAddr #TODO: Figure out why addr(buffer) throws error
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = self.inner.raw_reconcile(queryBufPtr, myResultPtr)
  if ret < 0:
    error "raw_reconcile failed with code ", code = ret
    return err($myResultPtr.error)
  trace "received return from raw_reconcile", len = myResultPtr.output.len

  let outputBytes: seq[byte] = bufferToBytes(addr(myResultPtr.output))
  trace "outputBytes len", len = outputBytes.len
  free_result(myResultPtr)

  return ok(NegentropyPayload(outputBytes))

method clientReconcile*(
    self: NegentropyWithStorage,
    query: NegentropyPayload,
    haves: var seq[WakuMessageHash],
    needs: var seq[WakuMessageHash],
): Result[Option[NegentropyPayload], string] =
  ## Client response to a negentropy payload.
  ## May return an answer, if not the sync session done.

  let cQuery = toBuffer(seq[byte](query))

  var myResult {.noinit.}: BindingResult = BindingResult()
  myResult.have_ids_len = 0
  myResult.need_ids_len = 0
  var myResultPtr = addr myResult

  let ret = self.inner.raw_reconcile_with_ids(cQuery.unsafeAddr, myResultPtr)
  if ret < 0:
    error "raw_reconcile failed with code ", code = ret
    return err($myResultPtr.error)

  let output = bufferToBytes(addr myResult.output)

  var
    have_hashes: seq[Buffer]
    need_hashes: seq[Buffer]

  if myResult.have_ids_len > 0:
    have_hashes = toBufferSeq(myResult.have_ids_len, myResult.have_ids)
  if myResult.need_ids_len > 0:
    need_hashes = toBufferSeq(myResult.need_ids_len, myResult.need_ids)

  trace "have and need hashes ",
    have_count = have_hashes.len, need_count = need_hashes.len

  for i in 0 .. have_hashes.len - 1:
    var hash = toWakuMessageHash(have_hashes[i])
    trace "have hashes ", index = i, msg_hash = hash.to0xHex()
    haves.add(hash)

  for i in 0 .. need_hashes.len - 1:
    var hash = toWakuMessageHash(need_hashes[i])
    trace "need hashes ", index = i, msg_hash = hash.to0xHex()
    needs.add(hash)

  trace "return ", output = output, len = output.len

  free_result(myResultPtr)

  if output.len < 1:
    return ok(none(NegentropyPayload))

  return ok(some(NegentropyPayload(output)))
