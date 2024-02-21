## Waku v2

# Waku core test suite
import ./waku_core/test_all

# Waku archive test suite
import ./waku_archive/test_all

# Waku store test suite
import ./waku_store/test_all

import
  ./node/test_all,
  ./waku_filter_v2/test_all,
  ./waku_peer_exchange/test_all,
  ./waku_lightpush/test_all,
  ./waku_relay/test_all

import
  # Waku v2 tests
  ./test_wakunode,
  ./test_wakunode_lightpush,
  # Waku Filter
  ./test_waku_filter_legacy,
  ./test_wakunode_filter_legacy,
  ./test_peer_store_extended,
  ./test_message_cache,
  ./test_peer_manager,
  ./test_peer_storage,
  ./test_waku_keepalive,
  ./test_waku_enr,
  ./test_waku_dnsdisc,
  ./test_relay_peer_exchange,
  ./test_waku_noise,
  ./test_waku_noise_sessions,
  ./test_waku_netconfig,
  ./test_waku_switch,
  ./test_waku_rendezvous

# Waku Keystore test suite
import ./test_waku_keystore_keyfile, ./test_waku_keystore

## Wakunode JSON-RPC API test suite
import ./wakunode_jsonrpc/test_all

## Wakunode Rest API test suite
import ./wakunode_rest/test_all

import ./waku_rln_relay/test_all

# import
#   ./waku_rln_relay/test_waku_rln_relay,
#   ./waku_rln_relay/test_wakunode_rln_relay,
#   ./waku_rln_relay/test_rln_group_manager_onchain,
#   ./waku_rln_relay/test_rln_group_manager_static

# Node Factory
import ./factory/test_node_factory
