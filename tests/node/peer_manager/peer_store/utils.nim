import std/options, stew/results, libp2p/peerstore

import
  ../../../../waku/node/peer_manager/[waku_peer_store, peer_store/waku_peer_storage],
  ../../../waku_archive/archive_utils

proc newTestWakuPeerStorage*(path: Option[string] = string.none()): WakuPeerStorage =
  let db = newSqliteDatabase(path)
  WakuPeerStorage.new(db).value()

proc peerExists*(peerStore: PeerStore, peerId: PeerId): bool =
  return peerStore[AddressBook].contains(peerId)
