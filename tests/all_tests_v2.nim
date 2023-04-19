## Waku v2

# Waku core test suite
import
  ./v2/waku_core/test_namespaced_topics,
  ./v2/waku_core/test_time,
  ./v2/waku_core/test_message_digest


# Waku archive test suite
import
  ./v2/waku_archive/test_driver_queue_index,
  ./v2/waku_archive/test_driver_queue_pagination,
  ./v2/waku_archive/test_driver_queue_query,
  ./v2/waku_archive/test_driver_queue,
  ./v2/waku_archive/test_driver_sqlite_query,
  ./v2/waku_archive/test_driver_sqlite,
  ./v2/waku_archive/test_retention_policy,
  ./v2/waku_archive/test_waku_archive

# Waku store test suite
import
  ./v2/waku_store/test_rpc_codec,
  ./v2/waku_store/test_waku_store,
  ./v2/waku_store/test_wakunode_store

when defined(waku_exp_store_resume):
  # TODO: Review store resume test cases (#1282)
  import ./v2/waku_store/test_resume


# Waku relay test suite
import
  ./v2/waku_relay/test_waku_relay,
  ./v2/waku_relay/test_wakunode_relay

# Waku filter test suite
import
  ./v2/waku_filter_v2/test_waku_filter,
  ./v2/waku_filter_v2/test_waku_filter_protocol

import
  # Waku v2 tests
  ./v2/test_wakunode,
  # Waku LightPush
  ./v2/test_waku_lightpush,
  ./v2/test_wakunode_lightpush,
  # Waku Filter
  ./v2/test_waku_filter,
  ./v2/test_wakunode_filter,
  ./v2/test_waku_peer_exchange,
  ./v2/test_peer_store_extended,
  ./v2/test_utils_peers,
  ./v2/test_message_cache,
  ./v2/test_peer_manager,
  ./v2/test_peer_storage,
  ./v2/test_waku_keepalive,
  ./v2/test_waku_enr,
  ./v2/test_waku_dnsdisc,
  ./v2/test_waku_discv5,
  ./v2/test_peer_exchange,
  ./v2/test_waku_noise,
  ./v2/test_waku_noise_sessions,
  ./v2/test_waku_switch,
  # Utils
  ./v2/test_utils_compat

# Waku Keystore test suite
import
  ./v2/test_waku_keystore_keyfile,
  ./v2/test_waku_keystore

## Wakunode JSON-RPC API test suite
import
  ./v2/wakunode_jsonrpc/test_jsonrpc_admin,
  ./v2/wakunode_jsonrpc/test_jsonrpc_debug,
  ./v2/wakunode_jsonrpc/test_jsonrpc_filter,
  ./v2/wakunode_jsonrpc/test_jsonrpc_relay,
  ./v2/wakunode_jsonrpc/test_jsonrpc_store

## Wakunode Rest API test suite
import
  ./v2/wakunode_rest/test_rest_debug,
  ./v2/wakunode_rest/test_rest_debug_serdes,
  ./v2/wakunode_rest/test_rest_relay,
  ./v2/wakunode_rest/test_rest_relay_serdes,
  ./v2/wakunode_rest/test_rest_serdes,
  ./v2/wakunode_rest/test_rest_store


## Apps

# Wakubridge test suite
import ./all_tests_wakubridge


## Experimental

when defined(rln):
  import
    ./v2/waku_rln_relay/test_waku_rln_relay,
    ./v2/waku_rln_relay/test_wakunode_rln_relay,
    ./v2/waku_rln_relay/test_rln_group_manager_onchain,
    ./v2/waku_rln_relay/test_rln_group_manager_static
