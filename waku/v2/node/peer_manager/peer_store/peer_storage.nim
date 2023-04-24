when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  stew/results
import
  ../../../waku_core,
  ../waku_peer_store

## This module defines a peer storage interface. Implementations of
## PeerStorage are used to store and retrieve peers

type
  PeerStorage* = ref object of RootObj

  PeerStorageResult*[T] = Result[T, string]

  DataProc* = proc(peerId: PeerID, remotePeerInfo: RemotePeerInfo,
                   connectedness: Connectedness, disconnectTime: int64) {.closure, raises: [Defect].}

# PeerStorage interface
method put*(db: PeerStorage,
            peerId: PeerID,
            remotePeerInfo: RemotePeerInfo,
            connectedness: Connectedness,
            disconnectTime: int64): PeerStorageResult[void] {.base.} = discard

method getAll*(db: PeerStorage, onData: DataProc): PeerStorageResult[bool] {.base.} = discard
