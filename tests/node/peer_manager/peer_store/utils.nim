import stew/results

import
  ../../../../waku/node/peer_manager/peer_store/waku_peer_storage,
  ../../../waku_archive/archive_utils

proc newTestWakuPeerStorage*(): WakuPeerStorage =
  let db = newSqliteDatabase()
  WakuPeerStorage.new(db).value()
