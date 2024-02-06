when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

import std/[strutils], chronicles, std/options, stew/[results, byteutils], confutils
import ../waku_core/message

const negentropyPath =
  currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & ".." & DirSep & ".." & DirSep &
  "vendor" & DirSep & "negentropy" & DirSep & "cpp" & DirSep

{.link: negentropyPath & "libnegentropy.so".}

const NEGENTROPY_HEADER = negentropyPath & "negentropy_wrapper.h"

logScope:
  topics = "waku sync"

type Buffer* = object
  len*: uint64
  `ptr`*: ptr uint8

type BindingResult* = object
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

proc toBuffer*(x: openArray[byte]): Buffer =
  ## converts the input to a Buffer object
  ## the Buffer object is used to communicate data with the rln lib
  var temp = @x
  let baseAddr = cast[pointer](x)
  let output = Buffer(`ptr`: cast[ptr uint8](baseAddr), len: uint64(temp.len))
  return output

proc BufferToBytes(buffer: ptr Buffer, len: Option[uint64] = none(uint64)): seq[byte] =
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

type Storage* = distinct pointer

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L27
proc storage_init(
  db_path: cstring, name: cstring
): Storage {.header: NEGENTROPY_HEADER, importc: "storage_new".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L41
proc raw_insert(
  storage: Storage, timestamp: uint64, id: ptr Buffer
): bool {.header: NEGENTROPY_HEADER, importc: "storage_insert".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L43
proc raw_erase(
  storage: Storage, timestamp: uint64, id: ptr Buffer
): bool {.header: NEGENTROPY_HEADER, importc: "storage_erase".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L29
proc free(storage: Storage) {.header: NEGENTROPY_HEADER, importc: "storage_delete".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L31
proc size*(
  storage: Storage
): cint {.header: NEGENTROPY_HEADER, importc: "storage_size".}

### Negentropy ###

type Negentropy* = distinct pointer

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L33
proc constructNegentropy(
  storage: Storage, frameSizeLimit: uint64
): Negentropy {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L37
proc raw_initiate(
  negentropy: Negentropy, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L39
proc raw_setInitiator(
  negentropy: Negentropy
) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L45
proc raw_reconcile(
  negentropy: Negentropy, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L51
proc raw_reconcile_with_ids(
  negentropy: Negentropy, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids_no_cbk".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L35
proc free(
  negentropy: Negentropy
) {.header: NEGENTROPY_HEADER, importc: "negentropy_delete".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L53
proc free_result(
  r: ptr BindingResult
) {.header: NEGENTROPY_HEADER, importc: "free_result".}

### SubRange ###

type SubRange* = distinct pointer

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L57
proc subrange_init(
  storage: Storage, startTimestamp: uint64, endTimestamp: uint64
): SubRange {.header: NEGENTROPY_HEADER, importc: "subrange_new".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L59
proc free(subrange: SubRange) {.header: NEGENTROPY_HEADER, importc: "subrange_delete".}

# https://github.com/waku-org/negentropy/blob/d4845b95b5a2d9bee28555833e7502db71bf319f/cpp/negentropy_wrapper.h#L31
proc size*(
  subrange: SubRange
): cint {.header: NEGENTROPY_HEADER, importc: "subrange_size".}

### Negentropy with SubRange ###

type NegentropySubRange* = distinct pointer

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L61
proc constructNegentropyWithSubRange(
  subrange: SubRange, frameSizeLimit: uint64
): NegentropySubRange {.header: NEGENTROPY_HEADER, importc: "negentropy_subrange_new".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L65
proc raw_initiate_subrange(
  negentropy: NegentropySubRange, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "negentropy_subrange_initiate".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L67
proc raw_reconcile_subrange(
  negentropy: NegentropySubRange, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile_subrange".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L69
proc raw_reconcile_with_ids_subrange(
  negentropy: NegentropySubRange, query: ptr Buffer, r: ptr BindingResult
): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids_subrange_no_cbk".}

# https://github.com/waku-org/negentropy/blob/3044a30e4ba2e218aee6dee2ef5b4a4b6f144865/cpp/negentropy_wrapper.h#L63
proc free(
  negentropy: NegentropySubRange
) {.header: NEGENTROPY_HEADER, importc: "negentropy_subrange_delete".}

### Wrappings ###

type NegentropyPayload* = distinct seq[byte]

proc `==`*(a: Storage, b: pointer): bool {.borrow.}

proc new*(T: type Storage): Result[T, string] =
  #TODO db name and path
  let storage = storage_init("", "")

  #[ TODO: Uncomment once we move to lmdb   
  if storage == nil:
    return err("storage initialization failed") ]#
  return ok(storage)

proc delete*(storage: Storage) =
  free(storage)

proc erase*(storage: Storage, id: int64, hash: WakuMessageHash): Result[void, string] =
  let cString = toBuffer(hash)

  let res = raw_erase(storage, uint64(id), cString.unsafeAddr)

  #TODO error handling once we move to lmdb

  if res:
    return ok()
  else:
    return err("erase error")

proc insert*(storage: Storage, id: int64, hash: WakuMessageHash): Result[void, string] =
  var buffer = toBuffer(hash)
  var bufPtr = addr(buffer)
  let res = raw_insert(storage, uint64(id), bufPtr)

  #TODO error handling once we move to lmdb

  if res:
    return ok()
  else:
    return err("insert error")

proc `==`*(a: NegentropySubRange, b: pointer): bool {.borrow.}

proc new*(
    T: type NegentropySubrange, subrange: SubRange, frameSizeLimit: int
): Result[T, string] =
  let negentropy = constructNegentropyWithSubRange(subrange, uint64(frameSizeLimit))
  if negentropy == nil:
    return err("negentropy initialization failed due to lower framesize")
  return ok(negentropy)

proc delete*(negentropy: NegentropySubRange) =
  free(negentropy)

proc initiate*(negentropy: NegentropySubrange): Result[NegentropyPayload, string] =
  ## Client inititate a sync session with a server by sending a payload 
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = raw_initiate_subrange(negentropy, myResultPtr)
  if ret < 0 or myResultPtr == nil:
    error "negentropy initiate failed with code ", code = ret
    return err("negentropy already initiated!")
  let bytes: seq[byte] = BufferToBytes(addr(myResultPtr.output))
  free_result(myResultPtr)
  trace "received return from initiate", len = myResultPtr.output.len

  return ok(NegentropyPayload(bytes))

proc setInitiator*(negentropy: Negentropy) =
  raw_setInitiator(negentropy)

proc serverReconcile*(
    negentropy: NegentropySubrange, query: NegentropyPayload
): Result[NegentropyPayload, string] =
  ## Server response to a negentropy payload.
  ## Always return an answer.

  let queryBuf = toBuffer(seq[byte](query))
  var queryBufPtr = queryBuf.unsafeAddr #TODO: Figure out why addr(buffer) throws error
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = raw_reconcile_subrange(negentropy, queryBufPtr, myResultPtr)
  if ret < 0:
    error "raw_reconcile failed with code ", code = ret
    return err($myResultPtr.error)
  trace "received return from raw_reconcile", len = myResultPtr.output.len

  let outputBytes: seq[byte] = BufferToBytes(addr(myResultPtr.output))
  trace "outputBytes len", len = outputBytes.len
  free_result(myResultPtr)

  return ok(NegentropyPayload(outputBytes))

proc clientReconcile*(
    negentropy: NegentropySubrange,
    query: NegentropyPayload,
    haveIds: var seq[WakuMessageHash],
    needIds: var seq[WakuMessageHash],
): Result[Option[NegentropyPayload], string] =
  ## Client response to a negentropy payload.
  ## May return an answer, if not the sync session done.

  let cQuery = toBuffer(seq[byte](query))

  var myResult {.noinit.}: BindingResult = BindingResult()
  myResult.have_ids_len = 0
  myResult.need_ids_len = 0
  var myResultPtr = addr myResult

  let ret = raw_reconcile_with_ids_subrange(negentropy, cQuery.unsafeAddr, myResultPtr)
  if ret < 0:
    error "raw_reconcile failed with code ", code = ret
    return err($myResultPtr.error)

  let output = BufferToBytes(addr myResult.output)

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
    trace "have hashes ", index = i, hash = hash.to0xHex()
    haveIds.add(hash)

  for i in 0 .. need_hashes.len - 1:
    var hash = toWakuMessageHash(need_hashes[i])
    trace "need hashes ", index = i, hash = hash.to0xHex()
    needIds.add(hash)

  trace "return ", output = output, len = output.len

  free_result(myResultPtr)

  if output.len < 1:
    return ok(none(NegentropyPayload))

  return ok(some(NegentropyPayload(output)))

### Subrange specific methods

proc new*(
    T: type SubRange,
    storage: Storage,
    startTime: uint64 = uint64.low,
    endTime: uint64 = uint64.high,
): Result[T, string] =
  let subrange = subrange_init(storage, startTime, endTime)

  #[ TODO: Uncomment once we move to lmdb   
  if storage == nil:
    return err("storage initialization failed") ]#
  return ok(subrange)

proc delete*(subrange: SubRange) =
  free(subrange)
