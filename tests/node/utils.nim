import
  results,
  logos_delivery/kernel/
    [node/peer_manager, kernel, enr/sharding, common/enr/typed_record],
  ../testlib/[wakucore]

proc relayShards*(node: Kernel): RelayShards =
  return node.enr.toTyped().get().relayShardingIndicesList().get()
