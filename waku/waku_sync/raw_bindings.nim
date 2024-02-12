when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils

import
   ../waku_core/message


{.link: "../waku_sync/negentropy.so".} #TODO build the dyn lib

### String ###

type
  String {.header: "<string>", importcpp: "std::string".} = object

proc size(self: String): csize_t {.header: "<string>", importcpp: "size".}
proc resize(self: String, len: csize_t) {.header: "<string>", importcpp: "resize".}
proc cStr(self: String): pointer {.header: "<string>", importcpp: "c_str".}
proc initString(): String {.header: "<string>", constructor, importcpp: "std::string()"}

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

  return cppString

### Vector ###

type
  Vector[T] {.header: "<vector>", importcpp: "std::vector".} = object
  VectorIter[T] {.header: "<vector>", importcpp: "std::vector<'0>::iterator".} = object

proc initVector[T](): Vector[T] {.importcpp: "std::vector<'*0>()", constructor, header: "<vector>".}
proc size(self: Vector): csize_t {.importcpp: "size", header: "<vector>".}
proc begin[T](self: Vector[T]): VectorIter[T] {.importcpp: "begin", header: "<vector>".}
proc `[]`[T](self: VectorIter[T]): T {.importcpp: "*#", header: "<vector>".}
proc next*[T](self: VectorIter[T]; n = 1): VectorIter[T] {.importcpp: "next(@)", header: "<iterator>".}

proc toSeq*[T](vec: Vector[T]): seq[T] =
  result = newSeq[T](vec.size())

  var itr = vec.begin()

  for i in 0..<vec.size():
    result[i] = itr[]
    itr = itr.next()

### Storage ###

type
  Storage* {.header: "<negentropy/storage/BTreeMem.h>", importcpp: "negentropy::storage::BTreeMem"} = object

#TODO if there's no constructor how do you instantiate this ???

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(this: Storage, timestamp: clong, id: String) {.importcpp: "negentropy::storage::btree::insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(this: Storage, timestamp: clong, id: String) {.importcpp: "negentropy::storage::btree::erase".}

### Negentropy ###

type
  Negentropy* {.header: "<negentropy/negentropy.h>", importCpp: "negentropy::Negentropy".} = object

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: Storage, frameSizeLimit: culong): Negentropy {.importcpp: "negentropy::Negentropy(@)", constructor.}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(this: Negentropy): String {.importcpp: "negentropy::initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(this: Negentropy) {.importcpp: "negentropy::setInitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(this: Negentropy, query: String): String {.importcpp: "negentropy::reconcile".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(this: Negentropy, query: String, haveIds: var Vector[String], needIds: var Vector[String]): String {.importcpp: "negentropy::reconcile".}

### Wrappings ###

proc new*(T: type Storage): T =
  let storage = Storage()

  return storage

proc erase*(self: Storage, id: int64, hash: WakuMessageHash) =
  let cppString = String.fromWakuMessageHash(hash)
  
  self.raw_erase(clong(id), cppString)

proc insert*(self: Storage, id: int64, hash: WakuMessageHash) =
  let cppString = String.fromWakuMessageHash(hash)
  
  self.raw_insert(clong(id), cppString)

proc new*(T: type Negentropy, storage: Storage, frameSizeLimit: uint64): T =
  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  return negentropy

proc initiate*(self: Negentropy): seq[byte] =
  let cppString = self.raw_initiate()

  let payload  = cppString.toBytes()

  return payload

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

  return payload