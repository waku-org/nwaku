when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

from os import DirSep

#[ import
  std/[strutils, sequtils]

import
   ../waku_core/message ]#

{.link: "../../vendor/negentropy/cpp/libnegentropy.so".} 

const negentropyPath = "../../vendor/negentropy/"

const NEGENTROPY_HEADER = negentropyPath & DirSep & "cpp" & DirSep & "negentropy_wrapper.h"

### String ###
#[ 
proc toBytes(self: String): seq[byte] =
  let size = self.size()

  var bytes = newSeq[byte](size)

  copyMem(bytes[0].addr, self.cStr(), size)

  return bytes

proc toWakuMessageHash(self: String): WakuMessageHash =
  assert self.size == 32

  var hash: WakuMessageHash

  copyMem(hash[0].addr, self.cStr(), 32)

  return hash

proc fromWakuMessageHash(T: type String, hash: WakuMessageHash): T  =
  let cppString = initString()

  cppString.resize(csize_t(32)) # add the null terminator at the end???

  copyMem(cppString.cStr(), hash[0].unsafeAddr, 32)

  return cppString

proc fromBytes(T: type String, bytes: seq[byte]): T =
  let size = bytes.len

  let cppString = initString()

  cppString.resize(csize_t(size)) # add the null terminator at the end???

  copyMem(cppString.cStr(), bytes[0].unsafeAddr, size)

  return cppString ]#

### Storage ###

proc Storage(db_path:cstring, name: cstring) :pointer{. header: NEGENTROPY_HEADER, importc: "storage_new".}

#[ # https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(this: Storage, timestamp: clong, id: String) {.importc: "negentropy::storage::btree::insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(this: Storage, timestamp: clong, id: String) {.importc: "negentropy::storage::btree::erase".}
 ]#
### Negentropy ###

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: pointer, frameSizeLimit: BiggestUInt): pointer {.importc: "negentropy_new".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(negentropy: pointer): cstring {.importc: "negentropy_initiate".}
#[ 
# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(this: Negentropy) {.importc: "negentropy::setInitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(this: Negentropy, query: String): String {.importc: "negentropy::reconcile".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(this: Negentropy, query: String, haveIds: var Vector[String], needIds: var Vector[String]): String {.importc: "negentropy::reconcile".}
 ]#
### Wrappings ###

proc new_storage*(): pointer =
  let storage = Storage("", "")

  return storage
#[ 
proc erase*(self: Storage, id: int64, hash: WakuMessageHash) =
  let cppString = String.fromWakuMessageHash(hash)
  
  self.raw_erase(clong(id), cppString)

proc insert*(self: Storage, id: int64, hash: WakuMessageHash) =
  let cppString = String.fromWakuMessageHash(hash)
  
  self.raw_insert(clong(id), cppString) ]#

proc new_negentropy*(storage: pointer, frameSizeLimit: uint64): pointer =
  let negentropy = constructNegentropy(storage, culong(frameSizeLimit))
  
  return negentropy

proc initiate*(negentropy: pointer): cstring =
  let cString = raw_initiate(negentropy)

  #let payload  = cString.toBytes()

  return cString
#[ 
proc setInitiator*(self: Negentropy) =
  self.raw_setInitiator()

proc serverReconcile*(self: Negentropy, query: seq[byte]): seq[byte] =
  let cppQuery = String.fromBytes(query)
  
  let cppString = self.raw_reconcile(cppQuery)

  let payload = cppString.toBytes()

  return payload

proc clientReconcile*(self: Negentropy, query: seq[byte], haveIds: var seq[WakuMessageHash], needIds: var seq[WakuMessageHash]): seq[byte] =
  let cppQuery = String.fromBytes(query)
  
  var 
    cppHaveIds = initVector[String]()
    cppNeedIds = initVector[String]()

  let cppString = self.raw_reconcile(cppQuery, cppHaveIds, cppNeedIds)

  let haveHashes = cppHaveIds.toSeq().mapIt(it.toWakuMessageHash())
  let needHashes = cppNeedIds.toSeq().mapIt(it.toWakuMessageHash())

  haveIds.add(haveHashes)
  needIds.add(needHashes)

  let payload = cppString.toBytes()

  return payload ]#