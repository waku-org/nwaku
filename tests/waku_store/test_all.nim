{.used.}

import ./test_client, ./test_rpc_codec, ./test_waku_store, ./test_wakunode_store

when defined(waku_exp_store_resume):
  # TODO: Review store resume test cases (#1282)
  import ./test_resume
