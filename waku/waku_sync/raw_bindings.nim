when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
   ../waku_core/message


{.link: "../waku_sync/negentropy.so".} #TODO build the dyn lib

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

proc fromBytes(T: type String, bytes: seq[byte]): T =
  let size = bytes.len

  let cppString = initString()

  cppString.resize(csize_t(size))

  copyMem(cppString.cStr(), bytes[0].unsafeAddr, size)

  return cppString

### Storage ###

type
  StorageObj {.header: "<negentropy/storage/BTreeMem.h>", importcpp: "negentropy::storage::BTreeMem"} = object

  Storage = ptr StorageObj

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(this: Storage, timestamp: clong, id: String) {.importcpp: "negentropy::storage::btree::insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(this: Storage, timestamp: clong, id: String) {.importcpp: "negentropy::storage::btree::erase".}

### Negentropy ###

type
  NegentropyObj {.header: "<negentropy/negentropy.h>", importCpp: "negentropy::Negentropy".} = object

  Negentropy* = ptr NegentropyObj

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: Storage, frameSizeLimit: culong): Negentropy {.importcpp: "negentropy::Negentropy(@)", constructor.}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(this: Negentropy): String {.importcpp: "negentropy::initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(this: Negentropy) {.importcpp: "negentropy::setInitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(this: Negentropy, query: String): String {.importcpp: "negentropy::reconcile".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(this: Negentropy, query: String, haveIds: var seq[String], needIds: var seq[String]): String {.importcpp: "negentropy::reconcile".}

### Bindings ###

#[ proc new*(T: type Negentropy, frameSizeLimit: uint64): T =

  let storage = Storage() # if there's no constructor how do you instantiate this ???

  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  return negentropy ]#

proc serverReconcile*(self: Negentropy, query: seq[byte]): seq[byte] =
  let cppQuery = String.fromBytes(query)
  
  let cppString = self.raw_reconcile(cppQuery)

  let payload = cppString.toBytes()

  return payload

#[ proc clientReconcile*(self: Negentropy, query: seq[byte], haveIds: var seq[WakuMessageHash], needIds: var seq[WakuMessageHash]): seq[byte] =
  let cppQuery = fromBytes(query)
  
  # How to go from seq[WakuMessageHash] to std::vector<std::string> ???
  var 
    haveIds: seq[WakuMessageHash]
    needIds: seq[WakuMessageHash]

  let cppString = self.raw_reconcile(cppQuery, var haveIds, var needIds)

  let payload = cppString.toBytes()

  return payload ]#