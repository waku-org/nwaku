when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

import
  std/[strutils, sequtils]

import
   ../waku_core/message

{.link: "../../vendor/negentropy/cpp/libnegentropy.so".} 

const NEGENTROPY_HEADER = "../../vendor/negentropy/" & DirSep & "cpp" & DirSep & "negentropy_wrapper.h"

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

proc WakuMessageHashToCString(hash: WakuMessageHash): cstring  =
  var cString = newString(32)

  copyMem(cString[0].addr, hash[0].unsafeAddr, 32)

  return cString

proc StringfromBytes(bytes: seq[byte]): cstring =
  let cString: string = bytes.mapIt(char(it)).join()

  return cString

### Storage ###

proc storage_init(db_path:cstring, name: cstring): pointer{. header: NEGENTROPY_HEADER, importc: "storage_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(storage: pointer, timestamp: uint64, id: cstring): bool {.header: NEGENTROPY_HEADER, importc: "storage_insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(storage: pointer, timestamp: uint64, id: cstring): bool {.header: NEGENTROPY_HEADER, importc: "storage_erase".}

### Negentropy ###

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: pointer, frameSizeLimit: uint64): pointer {.header: NEGENTROPY_HEADER, importc: "negentropy_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(negentropy: pointer): cstring {.header: NEGENTROPY_HEADER, importc: "negentropy_initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(negentropy: pointer) {.header: NEGENTROPY_HEADER, importc: "negentropy_setinitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(negentropy: pointer, query: cstring, querylen: uint): cstring {.header: NEGENTROPY_HEADER, importc: "reconcile".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(negentropy: pointer, query: cstring, querylen: uint, haveIds: cstringArray, haveIdsCount: pointer, needIds: cstringArray, needIdsCount: pointer): cstring {.header: NEGENTROPY_HEADER, importc: "reconcile_with_ids".}

### Wrappings ###

#TODO: Change all these methods to private as we don't want them to be exposed outside Sync package
proc new_storage*(): pointer =
  let storage = storage_init("", "")

  return storage

proc erase*(storage: pointer, id: int64, hash: WakuMessageHash): bool =
  let cString = WakuMessageHashToCString(hash)
  
  return raw_erase(storage, uint64(id), cString)

proc insert*(storage: pointer, id: int64, hash: WakuMessageHash): bool =
  let cString = WakuMessageHashToCString(hash)
  
  return raw_insert(storage, uint64(id), cString)

proc new_negentropy*(storage: pointer, frameSizeLimit: uint64): pointer =
  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  return negentropy

proc initiate*(negentropy: pointer): seq[byte] =
  let cString: cstring = raw_initiate(negentropy)

  return StringtoBytes(cString)


proc setInitiator*(negentropy: pointer) =
  raw_setInitiator(negentropy)

proc serverReconcile*(negentropy: pointer, query: seq[byte]): seq[byte] =
  let cQuery: cstring = StringfromBytes(query)

  let cppString:cstring = raw_reconcile(negentropy, cQuery, uint(query.len))

  return StringtoBytes(cppString)

proc clientReconcile*(negentropy: pointer, query: seq[byte], haveIds: var seq[WakuMessageHash], needIds: var seq[WakuMessageHash]): seq[byte] =
  let cppQuery: cstring = StringfromBytes(query)
  
  var 
    cppHaveIds: cstringArray = allocCStringArray([])
    cppNeedIds: cstringArray = allocCStringArray([])
    haveIdsLen: uint
    needIdsLen: uint

  let cppString: cstring = raw_reconcile(negentropy, cppQuery, uint(query.len), cppHaveIds, haveIdsLen.addr , cppNeedIds , needIdsLen.addr)

  for ele in cstringArrayToSeq(cppHaveIds, haveIdsLen):
    haveIds.add(toWakuMessageHash(ele))

  for ele in cstringArrayToSeq(cppNeedIds, needIdsLen):
    needIds.add(toWakuMessageHash(ele))

  deallocCStringArray(cppHaveIds)
  deallocCStringArray(cppNeedIds)

  let payload: seq[byte] = StringtoBytes(cppString)

  return payload