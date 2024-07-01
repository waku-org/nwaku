import std/options, results
import
  waku/node/peer_manager,
  waku/node/waku_node,
  waku/waku_enr/sharding,
  waku/common/enr/typed_record,
  ../testlib/[wakucore]

proc relayShards*(node: WakuNode): RelayShards =
  return node.enr.toTyped().get().relayShardingIndicesList().get()
