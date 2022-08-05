import
  # Waku v2 tests
  # TODO: enable this when it is altered into a proper waku relay test
  # ./v2/test_waku,
  ./v2/test_wakunode,
  ./v2/test_waku_store,
  ./v2/test_waku_filter,
  ./v2/test_waku_payload,
  ./v2/test_waku_swap,
  ./v2/test_utils_pagination,
  ./v2/test_message_store_queue_pagination,
  ./v2/test_message_store,
  ./v2/test_jsonrpc_waku,
  ./v2/test_rest_serdes,
  ./v2/test_rest_debug_api_serdes,
  ./v2/test_rest_debug_api,
  ./v2/test_rest_relay_api_serdes,
  ./v2/test_rest_relay_api_topic_cache,
  ./v2/test_rest_relay_api,
  ./v2/test_peer_manager,
  ./v2/test_web3, # TODO  remove it when rln-relay tests get finalized
  ./v2/test_waku_bridge,
  ./v2/test_peer_storage,
  ./v2/test_waku_keepalive,
  ./v2/test_migration_utils,
  ./v2/test_namespacing_utils,
  ./v2/test_waku_dnsdisc,
  ./v2/test_waku_discv5,
  ./v2/test_enr_utils,
  ./v2/test_waku_store_queue,
  ./v2/test_peer_exchange,
  ./v2/test_waku_noise

when defined(rln) or defined(rlnzerokit):
  import ./v2/test_waku_rln_relay
  when defined(onchain_rln):
    import ./v2/test_waku_rln_relay_onchain


# TODO Only enable this once swap module is integrated more nicely as a dependency, i.e. as submodule with CI etc
# For PoC execute it manually and run separate module here: https://github.com/vacp2p/swap-contracts-module
#  ./v2/test_waku_swap_contracts
