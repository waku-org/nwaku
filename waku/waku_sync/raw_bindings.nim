when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

import
   std/[strutils],
   ../waku_core/message,
   chronicles,
   std/options

const negentropyPath = currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & ".." & DirSep & ".." & DirSep & "vendor" & DirSep & "negentropy" & DirSep & "cpp" & DirSep

{.link: negentropyPath & "libnegentropy.so".} 

const NEGENTROPY_HEADER = negentropyPath & "negentropy_wrapper.h"


#[ proc StringtoBytes(data: cstring): seq[byte] =
  let size = data.len()

  var bytes = newSeq[byte](size)
  copyMem(bytes[0].addr, data[0].unsafeAddr, size)

  return bytes

proc toWakuMessageHash(data: string): WakuMessageHash =
  assert data.len() == 32

  var hash: WakuMessageHash

  copyMem(hash[0].addr, data.unsafeAddr, 32)

  return hash ]#

type Buffer* = object
  len*: uint64
  `ptr`*: ptr uint8

type ReconcileOutput* = object
  
  `output`*: ptr uint8

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
  debug "length of buffer is",len=bufLen
  let bytes = newSeq[byte](bufLen)
  copyMem(bytes[0].unsafeAddr, buffer.ptr, bufLen)
  return bytes

### Storage ###

proc storage_init(db_path:cstring, name: cstring): pointer{. header: NEGENTROPY_HEADER, importc: "storage_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(storage: pointer, timestamp: uint64, id: ptr Buffer): bool {.header: NEGENTROPY_HEADER, importc: "storage_insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(storage: pointer, timestamp: uint64, id: ptr Buffer): bool {.header: NEGENTROPY_HEADER, importc: "storage_erase".}

### Negentropy ###

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: pointer, frameSizeLimit: uint64): pointer {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(negentropy: pointer, output: ptr Buffer): int  {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(negentropy: pointer) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(negentropy: pointer, query: ptr Buffer, output: ptr Buffer): int {.header: NEGENTROPY_HEADER, importc: "reconcile".}

type
  ReconcileCallback = proc(have_ids: ptr Buffer, have_ids_len:uint64, need_ids: ptr Buffer, need_ids_len:uint64, output: ptr Buffer, outptr: var ptr cchar) {.cdecl, raises: [], gcsafe.}# {.header: NEGENTROPY_HEADER, importc: "reconcile_cbk".}


# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(negentropy: pointer, query: ptr Buffer, cbk: ReconcileCallback, output: ptr cchar): int {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids".}

### Wrappings ###

#TODO: Change all these methods to private as we don't want them to be exposed outside Sync package
#TODO: Wrap storage and negentropy with objects rather than using void pointers
proc new_storage*(): pointer =
  let storage = storage_init("", "")

  return storage

proc erase*(storage: pointer, id: int64, hash: WakuMessageHash): bool =
  let cString = toBuffer(hash)
  
  return raw_erase(storage, uint64(id), cString.unsafeAddr)

proc insert*(storage: pointer, id: int64, hash: WakuMessageHash): bool =
  var buffer = toBuffer(hash)
  var bufPtr = addr(buffer)
  return raw_insert(storage, uint64(id), bufPtr)

proc new_negentropy*(storage: pointer, frameSizeLimit: uint64): pointer =
  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  return negentropy

proc initiate*(negentropy: pointer): seq[byte] =
  var output:seq[byte] = newSeq[byte](153600)  #TODO: Optimize this using callback to avoid huge alloc
  var outBuffer: Buffer = toBuffer(output)
  let outLen: int = raw_initiate(negentropy, outBuffer.unsafeAddr)
  let bytes:seq[byte] = BufferToBytes(addr(outBuffer), some(uint64(outLen)))
  debug "received return from initiate", len=outLen
  return bytes

proc setInitiator*(negentropy: pointer) =
  raw_setInitiator(negentropy)

proc serverReconcile*(negentropy: pointer, query: seq[byte]): seq[byte] =
  let queryBuf = toBuffer(query)
  var queryBufPtr = queryBuf.unsafeAddr #TODO: Figure out why addr(buffer) throws error
  var output:seq[byte] = newSeq[byte](153600)  #TODO: Optimize this using callback to avoid huge alloc
  var outBuffer: Buffer = toBuffer(output)

  let outLen: int = raw_reconcile(negentropy, queryBufPtr, outBuffer.unsafeAddr)
  debug "received return from raw_reconcile", len=outLen

  let bytes = BufferToBytes(addr(outBuffer), some(uint64(outLen)))

  return bytes

proc clientReconcile*(negentropy: pointer, query: seq[byte], haveIds: var seq[WakuMessageHash], needIds: var seq[WakuMessageHash]): seq[byte] =
  let cQuery = toBuffer(query)
  
  var 
#[     cppHaveIds: cstringArray = allocCStringArray([])
    cppNeedIds: cstringArray = allocCStringArray([])
    haveIdsLen: uint
    needIdsLen: uint ]#
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
    error "exception raised from raw_reconcile", error=e.msg

  
#[   debug "haveIdsLen", len=haveIdsLen

  for ele in cstringArrayToSeq(cppHaveIds, haveIdsLen):
    haveIds.add(toWakuMessageHash(ele))

  for ele in cstringArrayToSeq(cppNeedIds, needIdsLen):
    needIds.add(toWakuMessageHash(ele))

  deallocCStringArray(cppHaveIds)
  deallocCStringArray(cppNeedIds) ]#
  debug "return " , output=output

  return output