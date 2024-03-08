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

#[ proc StringtoBytes(data: cstring): seq[byte] =
  let size = data.len()

  var bytes = newSeq[byte](size)
  copyMem(bytes[0].addr, data[0].unsafeAddr, size)

  return bytes ]#

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

### Negentropy ###

type
  Negentropy* = distinct pointer

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: Storage, frameSizeLimit: uint64): Negentropy {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(negentropy: Negentropy, output: ptr Buffer): int  {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(negentropy: Negentropy) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(negentropy: Negentropy, query: ptr Buffer, output: ptr Buffer): int {.header: NEGENTROPY_HEADER, importc: "reconcile".}
#[ 
type
  ReconcileCallback = proc(have_ids: ptr Buffer, have_ids_len:uint64, need_ids: ptr Buffer, need_ids_len:uint64, output: ptr Buffer, outptr: var ptr cchar) {.cdecl, raises: [], gcsafe.}# {.header: NEGENTROPY_HEADER, importc: "reconcile_cbk".}
 ]#

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
#proc raw_reconcile(negentropy: pointer, query: ptr Buffer, cbk: ReconcileCallback, output: ptr cchar): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids".}

proc free*(negentropy: Negentropy){.header: NEGENTROPY_HEADER, importc: "negentropy_delete".}

proc raw_reconcile(negentropy: Negentropy, query: ptr Buffer, r: ptr BindingResult){.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids_no_cbk".}

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
  
  var output:seq[byte] = newSeq[byte](153600)  #TODO: Optimize this using callback to avoid huge alloc
  var outBuffer: Buffer = toBuffer(output)
  let outLen: int = raw_initiate(negentropy, outBuffer.unsafeAddr)
  let bytes: seq[byte] = BufferToBytes(addr(outBuffer), some(uint64(outLen)))

  debug "received return from initiate", len=outLen
  
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
  var output:seq[byte] = newSeq[byte](153600)  #TODO: Optimize this using callback to avoid huge alloc
  var outBuffer: Buffer = toBuffer(output)

  let outLen: int = raw_reconcile(negentropy, queryBufPtr, outBuffer.unsafeAddr)
  debug "received return from raw_reconcile", len=outLen

  let outputBytes: seq[byte] = BufferToBytes(addr(outBuffer), some(uint64(outLen)))
  debug "outputBytes len", len=outputBytes.len
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

  raw_reconcile(negentropy, cQuery.unsafeAddr, myResultPtr)

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


#[  Callback Approach, to be uncommented later during optimization phase    
  var 
    cppHaveIds: cstringArray = allocCStringArray([])
    cppNeedIds: cstringArray = allocCStringArray([])
    haveIdsLen: uint
    needIdsLen: uint
    output: seq[byte] = newSeq[byte](1) #TODO: fix this hack.

  
    let handler:ReconcileCallback = proc(have_ids: ptr Buffer, have_ids_len:uint64, need_ids: ptr Buffer,
                                        need_ids_len:uint64, outBuffer: ptr Buffer, outptr: var ptr cchar) {.cdecl, raises: [], gcsafe.} = 
      debug "ReconcileCallback: Received needHashes from client:", len = need_ids_len  , outBufLen=outBuffer.len    
      if outBuffer.len > 0:
        let ret = BufferToBytes(outBuffer)
        outptr = cast[ptr cchar](ret[0].unsafeAddr)
      
  try:
    let ret  = raw_reconcile(negentropy, cQuery.unsafeAddr, handler, cast[ptr cchar](output[0].unsafeAddr))
    if ret != 0:
      error "failed to reconcile"
      return 
  except Exception as e:
    error "exception raised from raw_reconcile", error=e.msg ]#

  
#[   debug "haveIdsLen", len=haveIdsLen

  for ele in cstringArrayToSeq(cppHaveIds, haveIdsLen):
    haveIds.add(toWakuMessageHash(ele))

  for ele in cstringArrayToSeq(cppNeedIds, needIdsLen):
    needIds.add(toWakuMessageHash(ele))

  deallocCStringArray(cppHaveIds)
  deallocCStringArray(cppNeedIds) ]#
  free_result(myResultPtr)

  debug "return " , output=output

  if output.len < 1:
    return ok(none(NegentropyPayload))

  return ok(some(NegentropyPayload(output)))
