{.used.}

import ./rln/test_all,
  # ./test_rln_group_manager_onchain,
  # ./test_rln_group_manager_static,
  ./test_rln_nonce_manager,
  # ./test_waku_rln_relay,
  ./test_wakunode_rln_relay

when defined(rln_v2):
  import 
    ./rln_v2/test_all
