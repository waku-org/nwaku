import
  results,
  logos_delivery/kernel/
    [peer_manager, kernel, common/enr/sharding, common/enr/typed_record],
  ../testlib/[wakucore]

proc relayShards*(node: Kernel): RelayShards =
  return node.enr.toTyped().get().relayShardingIndicesList().get()
