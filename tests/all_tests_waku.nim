import
  # ./common/test_all, # In all_tests_common.nim
  ./factory/test_all,
  ./waku_archive/test_all,
  ./waku_core/test_all,
  ./waku_discv5/test_all,
  ./waku_enr/test_all,
  ./waku_filter_v2/test_all,
  ./waku_lightpush/test_all,
  ./waku_node/test_all,
  ./waku_peer_exchange/test_all,
  ./waku_relay/test_all,
  ./waku_rln_relay/test_all,
  ./waku_store/test_all,
  ./wakunode_rest/test_all 
  # ./wakunode2/test_all # In all_tests_wakunode2.nim

import
  ./test_message_cache, # Previously tagged as Waku Filter
  ./test_peer_manager, # Previously tagged as Waku Filter
  ./test_peer_storage, # Previously tagged as Waku Filter
  ./test_peer_store_extended, # Previously tagged as Waku Filter
  ./test_relay_peer_exchange, # Previously tagged as Waku Filter
  ./test_utils_compat.nim, # Wasn't added previously
  ./test_waku_dnsdisc, # Previously tagged as Waku Filter
  ./test_waku_enr, # Previously tagged as Waku Filter
  ./test_waku_filter_legacy, # Previously tagged as Waku Filter
  ./test_waku_keepalive, # Previously tagged as Waku Filter
  ./test_waku_keystore_keyfile, # Previously tagged as Waku Keystore
  ./test_waku_keystore, # Previously tagged as Waku Keystore
  ./test_waku_metadata, # Wasn't added previously
  ./test_waku_netconfig, # Previously tagged as Waku Filter
  ./test_waku_noise_sessions, # Previously tagged as Waku Filter
  ./test_waku_noise, # Previously tagged as Waku Filter
  ./test_waku_protobufs, # Wasn't added previously
  ./test_waku_rendezvous, # Previously tagged as Waku Filter
  ./test_waku_switch, # Previously tagged as Waku Filter
  ./test_wakunode_filter_legacy, # Previously tagged as Waku Filter
  ./test_wakunode_lightpush, # Previously tagged as Waku v2
  ./test_wakunode # Previously tagged as Waku v2
