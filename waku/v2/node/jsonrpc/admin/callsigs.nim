# Admin API

proc get_waku_v2_admin_v1_peers(): seq[WakuPeer]
proc post_waku_v2_admin_v1_peers(peers: seq[string]): bool
