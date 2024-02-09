when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
   ../waku_core/message


{.link: "../waku_sync/negentropy.so".} #TODO build the dyn lib

type
  StdString {.header: "<string>", importcpp: "std::string".} = object

### Storage ###

type
  StorageObj {.header: "<negentropy/storage/BTreeMem.h>", importcpp: "negentropy::storage::BTreeMem"} = object

  Storage = ptr StorageObj

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc raw_insert(this: Storage, timestamp: clong, id: StdString) {.importcpp: "negentropy::storage::btree::insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc raw_erase(this: Storage, timestamp: clong, id: StdString) {.importcpp: "negentropy::storage::btree::erase".}

### Negentropy ###

type
  NegentropyObj {.header: "<negentropy/negentropy.h>", importCpp: "negentropy::Negentropy".} = object

  Negentropy = ptr NegentropyObj

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: Storage, frameSizeLimit: culong): Negentropy {.importcpp: "negentropy::Negentropy(@)", constructor.}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc raw_initiate(this: Negentropy): StdString {.importcpp: "negentropy::initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc raw_setInitiator(this: Negentropy) {.importcpp: "negentropy::setInitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc raw_reconcile(this: Negentropy, query: StdString): StdString {.importcpp: "negentropy::reconcile".}

# How to update haveIDs and needIds from C++ side ???

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc raw_reconcile(this: Negentropy, query: StdString, haveIds: var seq[StdString], needIds: var seq[StdString]): StdString {.importcpp: "negentropy::reconcile".}

### Bindings ###

#[ proc new*(T: type Negentropy, frameSizeLimit: uint64): T =

  let storage = Storage() # if there's no constructor how do you instantiate this ???

  let negentropy = constructNegentropy(storage, frameSizeLimit)
  
  return negentropy ]#

#[ proc reconcile*(self: Negentropy, query: seq[byte], haveIds: var seq[WakuMessageHash], needIds: var seq[WakuMessageHash]): seq[byte] =
  let cppQuery = query.into() # TODO How do we turn Nim seq[byte] into C++ StdString ???
  
  # How to go from seq[WakuMessageHash] to std::vector<std::string> ???
  var 
    haveIds: seq[WakuMessageHash]
    needIds: seq[WakuMessageHash]

  let cppString = self.raw_reconcile(cppQuery, var haveIds, var needIds)

  let payload = cppString.into()  # TODO How do we turn C++ StdString into a useable Nim seq[byte] ???

  return payload ]#