## Waku v2

# Waku core test suite
import
  ./waku_core/test_namespaced_topics,
  ./waku_core/test_time,
  ./waku_core/test_message_digest,
  ./waku_core/test_peers,
  ./waku_core/test_published_address


# Waku archive test suite
import
  ./waku_archive/test_driver_queue_index,
  ./waku_archive/test_driver_queue_pagination,
  ./waku_archive/test_driver_queue_query,
  ./waku_archive/test_driver_queue,
  ./waku_archive/test_driver_sqlite_query,
  ./waku_archive/test_driver_sqlite,
  ./waku_archive/test_retention_policy,
  ./waku_archive/test_waku_archive

const os* {.strdefine.} = ""
when os == "Linux" and
  # GitHub only supports container actions on Linux
  # and we need to start a postgress database in a docker container
  defined(postgres):
  import
    ./waku_archive/test_driver_postgres_query,
    ./waku_archive/test_driver_postgres

# Waku store test suite
import
  ./waku_store/test_rpc_codec,
  ./waku_store/test_waku_store,
  ./waku_store/test_wakunode_store

when defined(waku_exp_store_resume):
  # TODO: Review store resume test cases (#1282)
  import ./waku_store/test_resume


# Waku relay test suite
import
  ./waku_relay/test_waku_relay,
  ./waku_relay/test_wakunode_relay

# Waku filter test suite
import
  ./waku_filter_v2/test_waku_client,
  ./waku_filter_v2/test_waku_filter,
  ./waku_filter_v2/test_waku_filter_protocol

import
  # Waku v2 tests
  ./test_wakunode,
  # Waku LightPush
  ./test_waku_lightpush,
  ./test_wakunode_lightpush,
  # Waku Filter
  ./test_waku_filter_legacy,
  ./test_wakunode_filter_legacy,
  ./test_waku_peer_exchange,
  ./test_peer_store_extended,
  ./test_message_cache,
  ./test_peer_manager,
  ./test_peer_storage,
  ./test_waku_keepalive,
  ./test_waku_enr,
  ./test_waku_dnsdisc,
  ./test_waku_discv5,
  ./test_peer_exchange,
  ./test_waku_noise,
  ./test_waku_noise_sessions,
  ./test_waku_netconfig,
  ./test_waku_switch,
  ./test_waku_rendezvous

# Waku Keystore test suite
import
  ./test_waku_keystore_keyfile,
  ./test_waku_keystore

## Wakunode JSON-RPC API test suite
import
  ./wakunode_jsonrpc/test_jsonrpc_admin,
  ./wakunode_jsonrpc/test_jsonrpc_debug,
  ./wakunode_jsonrpc/test_jsonrpc_filter,
  ./wakunode_jsonrpc/test_jsonrpc_relay,
  ./wakunode_jsonrpc/test_jsonrpc_store

## Wakunode Rest API test suite
import
  ./wakunode_rest/test_rest_debug,
  ./wakunode_rest/test_rest_debug_serdes,
  ./wakunode_rest/test_rest_relay,
  ./wakunode_rest/test_rest_relay_serdes,
  ./wakunode_rest/test_rest_serdes,
  ./wakunode_rest/test_rest_store,
  ./wakunode_rest/test_rest_filter,
  ./wakunode_rest/test_rest_legacy_filter,
  ./wakunode_rest/test_rest_lightpush

import
  ./waku_rln_relay/test_waku_rln_relay,
  ./waku_rln_relay/test_wakunode_rln_relay,
  ./waku_rln_relay/test_rln_group_manager_onchain,
  ./waku_rln_relay/test_rln_group_manager_static,
  ./wakunode_rest/test_rest_health
