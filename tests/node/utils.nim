import
  logos_delivery/kernel/[peer_manager, kernel, base/enr/sharding, base/enr/typed_record],
  results,
  ../testlib/wakucore
proc relayShards*(node: Kernel): RelayShards =
  return node.enr.toTyped().get().relayShardingIndicesList().get()
