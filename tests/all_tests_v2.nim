import
  # Waku common test suite
  ./v2/test_envvar_serialization,
  ./v2/test_confutils_envvar,
  ./v2/test_sqlite_migrations

import
  # Waku archive test suite
  ./v2/waku_archive/test_driver_queue_index,
  ./v2/waku_archive/test_driver_queue_pagination,
  ./v2/waku_archive/test_driver_queue_query,
  ./v2/waku_archive/test_driver_queue,
  ./v2/waku_archive/test_driver_sqlite_query,
  ./v2/waku_archive/test_driver_sqlite,
  ./v2/waku_archive/test_retention_policy,
  ./v2/waku_archive/test_waku_archive,

  # TODO: Remove with the implementation
  ./v2/test_message_store_queue_index,
  ./v2/test_message_store_queue_pagination,
  ./v2/test_message_store_queue,
  ./v2/test_message_store_sqlite_query,
  ./v2/test_message_store_sqlite

import
  # Waku v2 tests
  ./v2/test_wakunode,
  ./v2/test_wakunode_relay,
  # Waku Store
  ./v2/test_waku_store_rpc_codec,
  ./v2/test_waku_store,
  ./v2/test_waku_store_client,
  # TODO: Re-enable store resume test cases (#1282)
  # ./v2/test_waku_store_resume,
  ./v2/test_wakunode_store,
  # Waku LightPush
  ./v2/test_waku_lightpush,
  ./v2/test_wakunode_lightpush,
  # Waku Filter
  ./v2/test_waku_filter,
  ./v2/test_wakunode_filter,
  ./v2/test_waku_peer_exchange,
  ./v2/test_waku_payload,
  ./v2/test_waku_swap,
  ./v2/test_utils_peers,
  ./v2/test_message_cache,
  ./v2/test_jsonrpc_waku,
  ./v2/test_rest_serdes,
  ./v2/test_rest_debug_api_serdes,
  ./v2/test_rest_debug_api,
  ./v2/test_rest_relay_api_serdes,
  ./v2/test_rest_relay_api,
  ./v2/test_peer_manager,
  ./v2/test_web3, # TODO  remove it when rln-relay tests get finalized
  ./v2/test_waku_bridge,
  ./v2/test_peer_storage,
  ./v2/test_waku_keepalive,
  ./v2/test_namespacing_utils,
  ./v2/test_waku_dnsdisc,
  ./v2/test_waku_discv5,
  ./v2/test_enr_utils,
  ./v2/test_peer_exchange,
  ./v2/test_waku_noise,
  ./v2/test_waku_noise_sessions,
  # Utils
  ./v2/test_utils_keyfile

when defined(rln):
  import
    ./v2/test_waku_rln_relay,
    ./v2/test_wakunode_rln_relay
  when defined(onchain_rln):
    import ./v2/test_waku_rln_relay_onchain


# TODO Only enable this once swap module is integrated more nicely as a dependency, i.e. as submodule with CI etc
# For PoC execute it manually and run separate module here: https://github.com/vacp2p/swap-contracts-module
#  ./v2/test_waku_swap_contracts
