{.used.}

import
  ./test_rln_group_manager_onchain,
  ./test_rln_group_manager_static,
  ./test_waku_rln_relay,
  ./test_wakunode_rln_relay,
  ./test_rln_nonce_manager

when defined(rln_v2):
  import ./rln_v2/test_rln_relay_v2_serde
