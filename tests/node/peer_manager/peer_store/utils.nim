import results

import
  logos_delivery/kernel/peer_manager/[peer_store, peer_store/sqlite_peer_storage],
  ../../../waku_archive/archive_utils

proc newTestWakuPeerStorage*(path: Opt[string] = Opt.none(string)): WakuPeerStorage =
  let db = newSqliteDatabase(path)
  WakuPeerStorage.new(db).value()
