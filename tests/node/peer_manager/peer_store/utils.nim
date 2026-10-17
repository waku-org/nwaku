import results

import
  logos_delivery/kernel/node/peer_manager/
    [waku_peer_store, peer_store/waku_peer_storage],
  ../../../waku_archive/archive_utils

proc newTestWakuPeerStorage*(path: Opt[string] = Opt.none(string)): WakuPeerStorage =
  let db = newSqliteDatabase(path)
  WakuPeerStorage.new(db).value()
