{.push raises: [].}

import results
import logos_delivery/kernel/[common/peers, peer_manager/peer_store]
## This module defines a peer storage interface. Implementations of
## PeerStorage are used to store and retrieve peers

type
  PeerStorage* = ref object of RootObj

  PeerStorageResult*[T] = Result[T, string]

  DataProc* = proc(remotePeerInfo: RemotePeerInfo) {.closure, gcsafe, raises: [Defect].}

# PeerStorage interface
method put*(
    db: PeerStorage, remotePeerInfo: RemotePeerInfo
): PeerStorageResult[void] {.base, gcsafe.} =
  return err("Unimplemented")

method getAll*(
    db: PeerStorage, onData: DataProc
): PeerStorageResult[void] {.base, gcsafe.} =
  return err("Unimplemented")
