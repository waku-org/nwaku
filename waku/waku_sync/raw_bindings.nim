when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

import
   std/[strutils],
   chronicles,
   std/options,
   stew/[results, byteutils]
import
  ../waku_core/message

const negentropyPath = currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & ".." & DirSep & ".." & DirSep & "vendor" & DirSep & "negentropy" & DirSep & "cpp" & DirSep

{.link: negentropyPath & "libnegentropy.so".} 

const NEGENTROPY_HEADER = negentropyPath & "negentropy_wrapper.h"

type Buffer* = object
  len*: uint64
  `ptr`*: ptr uint8

type BindingResult* = object
  output: Buffer
  have_ids_len: uint
  need_ids_len: uint
  have_ids: ptr Buffer
  need_ids: ptr Buffer

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

proc BufferToBytes(buffer: ptr Buffer, len: Option[uint64] = none(uint64)):seq[byte] =
  var bufLen: uint64
  if isNone(len):
    bufLen = buffer.len
  else:
    bufLen = len.get()
  if bufLen == 0:
    return @[]
  debug "length of buffer is",len=bufLen
  let bytes = newSeq[byte](bufLen)
  copyMem(bytes[0].unsafeAddr, buffer.ptr, bufLen)
  return bytes

proc toBufferSeq(buffLen: uint, buffPtr: ptr Buffer): seq[Buffer] =
    var uncheckedArr = cast[ptr UncheckedArray[Buffer]](buffPtr)
    var mySequence = newSeq[Buffer](buffLen)
    for i in 0..buffLen-1:
        mySequence[i] = uncheckedArr[i]
    return mySequence

### Storage ###

type
  Storage* = distinct pointer

proc storage_init(db_path:cstring, name: cstring): Storage{. header: NEGENTROPY_HEADER, importc: "storage_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(storage: Storage, timestamp: uint64, id: ptr Buffer): bool {.header: NEGENTROPY_HEADER, importc: "storage_insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(storage: Storage, timestamp: uint64, id: ptr Buffer): bool {.header: NEGENTROPY_HEADER, importc: "storage_erase".}

proc free*(storage: Storage){.header: NEGENTROPY_HEADER, importc: "storage_delete".}

proc size*(storage: Storage):cint {.header: NEGENTROPY_HEADER, importc: "storage_size".}

### Negentropy ###

type
  Negentropy* = distinct pointer

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: Storage, frameSizeLimit: uint64): Negentropy {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(negentropy: Negentropy, r: ptr BindingResult): int  {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(negentropy: Negentropy) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(negentropy: Negentropy, query: ptr Buffer, r: ptr BindingResult): int {.header: NEGENTROPY_HEADER, importc: "reconcile".}
#[ 
type
  ReconcileCallback = proc(have_ids: ptr Buffer, have_ids_len:uint64, need_ids: ptr Buffer, need_ids_len:uint64, output: ptr Buffer, outptr: var ptr cchar) {.cdecl, raises: [], gcsafe.}# {.header: NEGENTROPY_HEADER, importc: "reconcile_cbk".}
 ]#

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
#proc raw_reconcile(negentropy: pointer, query: ptr Buffer, cbk: ReconcileCallback, output: ptr cchar): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids".}

proc free*(negentropy: Negentropy){.header: NEGENTROPY_HEADER, importc: "negentropy_delete".}

proc raw_reconcile_with_ids(negentropy: Negentropy, query: ptr Buffer, r: ptr BindingResult){.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids_no_cbk".}

proc free_result(r: ptr BindingResult){.header: NEGENTROPY_HEADER, importc: "free_result".}

### Wrappings ###

type
  NegentropyPayload* = distinct seq[byte]

proc new*(T: type Storage): T =
  #TODO db name and path
  let storage = storage_init("", "")

  #TODO error handling

  return storage

proc erase*(storage: Storage, id: int64, hash: WakuMessageHash): Result[void, string] =
  let cString = toBuffer(hash)
  
  let res = raw_erase(storage, uint64(id), cString.unsafeAddr)

  #TODO error handling

  if res:
    return ok()
  else:
    return err("erase error")

proc insert*(storage: Storage, id: int64, hash: WakuMessageHash): Result[void, string] =
  var buffer = toBuffer(hash)
  var bufPtr = addr(buffer)
  let res = raw_insert(storage, uint64(id), bufPtr)
  
  #TODO error handling

  if res:
    return ok()
  else:
    return err("insert error")

proc new*(T: type Negentropy, storage: Storage, frameSizeLimit: uint64): T =
  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  #TODO error handling

  return negentropy

proc initiate*(negentropy: Negentropy): Result[NegentropyPayload, string] =
  ## Client inititate a sync session with a server by sending a payload 
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = raw_initiate(negentropy, myResultPtr)
  if ret < 0 or myResultPtr == nil:
    error "negentropy initiate failed with code ", code=ret
    return err("ERROR from raw_initiate!")
  let bytes: seq[byte] = BufferToBytes(addr(myResultPtr.output))
  free_result(myResultPtr)
  debug "received return from initiate", len=myResultPtr.output.len
  
  return ok(NegentropyPayload(bytes))

proc setInitiator*(negentropy: Negentropy) =
  raw_setInitiator(negentropy)

proc serverReconcile*(
  negentropy: Negentropy,
  query: NegentropyPayload,
  ): Result[NegentropyPayload, string] =
  ## Server response to a negentropy payload.
  ## Always return an answer.
  
  let queryBuf = toBuffer(seq[byte](query))
  var queryBufPtr = queryBuf.unsafeAddr #TODO: Figure out why addr(buffer) throws error
  var myResult {.noinit.}: BindingResult = BindingResult()
  var myResultPtr = addr myResult

  let ret = raw_reconcile(negentropy, queryBufPtr, myResultPtr)
  if ret < 0 or myResultPtr == nil:
    error "raw_reconcile failed with code ", code=ret
    return err("ERROR from raw_reconcile!")
  debug "received return from raw_reconcile", len=myResultPtr.output.len

  let outputBytes: seq[byte] = BufferToBytes(addr(myResultPtr.output))
  debug "outputBytes len", len=outputBytes.len
  free_result(myResultPtr)
  #TODO error handling

  return ok(NegentropyPayload(outputBytes))

proc clientReconcile*(
  negentropy: Negentropy,
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

  raw_reconcile_with_ids(negentropy, cQuery.unsafeAddr, myResultPtr)

  if myResultPtr == nil:
    return err("ERROR from raw_reconcile!")

  let output = BufferToBytes(addr myResult.output)

  var 
    have_hashes: seq[Buffer]  
    need_hashes: seq[Buffer] 

  if myResult.have_ids_len > 0:
    have_hashes = toBufferSeq(myResult.have_ids_len, myResult.have_ids)
  if myResult.need_ids_len > 0:
    need_hashes = toBufferSeq(myResult.need_ids_len, myResult.need_ids)

  debug "have and need hashes ",have_count=have_hashes.len, need_count=need_hashes.len

  for i in 0..have_hashes.len - 1:
    var hash = toWakuMessageHash(have_hashes[i])
    debug "have hashes ", index=i, hash=hash.to0xHex()
    haveIds.add(hash)

  for i in 0..need_hashes.len - 1:
    var hash = toWakuMessageHash(need_hashes[i])
    debug "need hashes ", index=i, hash=hash.to0xHex()
    needIds.add(hash)

  debug "return " , output=output, len = output.len

  free_result(myResultPtr)

  if output.len < 1:
    return ok(none(NegentropyPayload))

  return ok(some(NegentropyPayload(output)))