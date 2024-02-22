when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

import
   std/[strutils],
   ../waku_core/message,
   chronicles

const negentropyPath = currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & ".." & DirSep & ".." & DirSep & "vendor" & DirSep & "negentropy" & DirSep & "cpp" & DirSep

{.link: negentropyPath & "libnegentropy.so".} 

const NEGENTROPY_HEADER = negentropyPath & "negentropy_wrapper.h"

proc StringtoBytes(data: cstring): seq[byte] =
  let size = data.len()

  var bytes = newSeq[byte](size)
  copyMem(bytes[0].addr, data[0].unsafeAddr, size)

  return bytes

proc toWakuMessageHash(data: string): WakuMessageHash =
  assert data.len() == 32

  var hash: WakuMessageHash

  copyMem(hash[0].addr, data.unsafeAddr, 32)

  return hash

type Buffer* = object
  len*: uint64
  `ptr`*: ptr uint8


proc toBuffer*(x: openArray[byte]): Buffer =
  ## converts the input to a Buffer object
  ## the Buffer object is used to communicate data with the rln lib
  var temp = @x
  let baseAddr = cast[pointer](x)
  let output = Buffer(`ptr`: cast[ptr uint8](baseAddr), len: uint64(temp.len))
  return output

proc BufferToBytes(buffer: ptr Buffer):seq[byte] =
  let bytes = newSeq[byte](buffer.len)
  copyMem(bytes[0].unsafeAddr, buffer.ptr, buffer.len)
  return bytes

### Storage ###

proc storage_init(db_path:cstring, name: cstring): pointer{. header: NEGENTROPY_HEADER, importc: "storage_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(storage: pointer, timestamp: uint64, id:  ptr Buffer): bool {.header: NEGENTROPY_HEADER, importc: "storage_insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(storage: pointer, timestamp: uint64, id: ptr Buffer): bool {.header: NEGENTROPY_HEADER, importc: "storage_erase".}

### Negentropy ###

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: pointer, frameSizeLimit: uint64): pointer {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(negentropy: pointer): ptr Buffer {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(negentropy: pointer) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(negentropy: pointer, query: ptr Buffer): cstring {.header: NEGENTROPY_HEADER, importc: "reconcile".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(negentropy: pointer, query: ptr Buffer, haveIds: cstringArray, haveIdsCount: pointer, needIds: cstringArray, needIdsCount: pointer): cstring {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids".}

### Wrappings ###

#TODO: Change all these methods to private as we don't want them to be exposed outside Sync package
proc new_storage*(): pointer =
  let storage = storage_init("", "")

  return storage

proc erase*(storage: pointer, id: int64, hash: WakuMessageHash): bool =
  let cString = toBuffer(hash)
  
  return raw_erase(storage, uint64(id), cString.unsafeAddr)

proc insert*(storage: pointer, id: int64, hash: WakuMessageHash): bool =
  let cString = toBuffer(hash)
  debug "converted cstring ", len=cString.len
  return raw_insert(storage, uint64(id), cString.unsafeAddr)

proc new_negentropy*(storage: pointer, frameSizeLimit: uint64): pointer =
  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  return negentropy

proc initiate*(negentropy: pointer): seq[byte] =
  let cString = raw_initiate(negentropy)

  return BufferToBytes(cString)


proc setInitiator*(negentropy: pointer) =
  raw_setInitiator(negentropy)

proc serverReconcile*(negentropy: pointer, query: seq[byte]): seq[byte] =
  let cQuery = toBuffer(query)

  let cppString:cstring = raw_reconcile(negentropy, cQuery.unsafeAddr)

  return StringtoBytes(cppString)

proc clientReconcile*(negentropy: pointer, query: seq[byte], haveIds: var seq[WakuMessageHash], needIds: var seq[WakuMessageHash]): seq[byte] =
  let cQuery = toBuffer(query)
  
  var 
    cppHaveIds: cstringArray = allocCStringArray([])
    cppNeedIds: cstringArray = allocCStringArray([])
    haveIdsLen: uint
    needIdsLen: uint

  let cppString: cstring = raw_reconcile(negentropy, cQuery.unsafeAddr, cppHaveIds, haveIdsLen.addr , cppNeedIds , needIdsLen.addr)
  
  debug "haveIdsLen", len=haveIdsLen

  for ele in cstringArrayToSeq(cppHaveIds, haveIdsLen):
    haveIds.add(toWakuMessageHash(ele))

  for ele in cstringArrayToSeq(cppNeedIds, needIdsLen):
    needIds.add(toWakuMessageHash(ele))

  deallocCStringArray(cppHaveIds)
  deallocCStringArray(cppNeedIds)
  debug "return " , output=cppString
  let payload: seq[byte] = StringtoBytes(cppString)

  return payload