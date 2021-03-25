import
  stew/results,
  chronos,
  ../../peer_manager/waku_peer_store

## This module defines a peer storage interface. Implementations of
## PeerStorage are used to store and retrieve peers

type
  PeerStorage* = ref object of RootObj
  
  PeerStorageResult*[T] = Result[T, string]

  DataProc* = proc(peerId: PeerID, storedInfo: StoredInfo,
                   connectedness: Connectedness) {.closure.}

# PeerStorage interface
method put*(db: PeerStorage,
            peerId: PeerID,
            storedInfo: StoredInfo,
            connectedness: Connectedness): PeerStorageResult[void] {.base.} = discard

method getAll*(db: PeerStorage, onData: DataProc): PeerStorageResult[bool] {.base.} = discard