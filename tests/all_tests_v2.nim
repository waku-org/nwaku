import
  # Waku v2 tests
  # TODO: enable this when it is altered into a proper waku relay test
  # ./v2/test_waku,
  ./v2/test_wakunode,
  ./v2/test_waku_store,
  ./v2/test_waku_filter,
  ./v2/test_waku_pagination,
  ./v2/test_waku_payload,
  ./v2/test_waku_swap,
  ./v2/test_message_store,
  ./v2/test_jsonrpc_waku,
  ./v2/test_peer_manager,
  ./v2/test_web3, # TODO  remove it when rln-relay tests get finalized
  ./v2/test_waku_bridge,
  ./v2/test_peer_storage,
  ./v2/test_waku_keepalive,
  ./v2/test_migration_utils

when defined(rln):
  import ./v2/test_waku_rln_relay


# TODO Only enable this once swap module is integrated more nicely as a dependency, i.e. as submodule with CI etc
# For PoC execute it manually and run separate module here: https://github.com/vacp2p/swap-contracts-module
#  ./v2/test_waku_swap_contracts
