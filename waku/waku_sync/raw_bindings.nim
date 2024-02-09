when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


{.link: "../waku_sync/negentropy.so".}

type
  StdString {.header: "<string>", importcpp: "std::string".} = object

### Storage ###

type
  StorageObj {.header: "<negentropy/storage/BTreeMem.h>", importcpp: "negentropy::storage::BTreeMem"} = object

  Storage = ptr StorageObj

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L163
proc insert(this: Storage, timestamp: clong, id: StdString) {.importcpp: "negentropy::storage::btree::insert".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy/storage/btree/core.h#L300
proc erase(this: Storage, timestamp: clong, id: StdString) {.importcpp: "negentropy::storage::btree::erase".}

### Negentropy ###

type
  NegentropyObj {.header: "<negentropy/negentropy.h>", importCpp: "negentropy::Negentropy".} = object

  Negentropy = ptr NegentropyObj

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L42
proc constructNegentropy(storage: Storage, frameSizeLimit: culong): Negentropy {.importcpp: "negentropy::Negentropy(@)", constructor.}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L46
proc initiate(this: Negentropy): StdString {.importcpp: "negentropy::initiate".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L58
proc setInitiator(this: Negentropy) {.importcpp: "negentropy::setInitiator".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L62
proc reconcile(this: Negentropy, query: StdString): StdString {.importcpp: "negentropy::reconcile".}

# https://github.com/hoytech/negentropy/blob/6e1e6083b985adcdce616b6bb57b6ce2d1a48ec1/cpp/negentropy.h#L69
proc reconcile(this: Negentropy, query: StdString, haveIds: var seq[StdString], needIds: var seq[StdString]): StdString {.importcpp: "negentropy::reconcile".}