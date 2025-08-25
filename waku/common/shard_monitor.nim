{.push raises: [].}

import std/sets, sequtils, results, chronicles
import ../waku_core/topics/pubsub_topic

type ShardMonitor* = ref object
  subscribedShards: HashSet[uint16]

type ShardsGetter* = proc(): seq[uint16] {.gcsafe, raises: [].}

proc new*(T: type ShardMonitor): T =
  let sm = ShardMonitor(subscribedShards: initHashSet[uint16]())
  return sm

proc getSubscribedShards*(self: ShardMonitor): seq[uint16] =
  return toseq(self.subscribedShards)

#This is implemented temporarily until all shard related refs are moved to uint16
proc getSubscribedShardsUint32*(self: ShardMonitor): seq[uint32] =
  return self.subscribedShards.mapIt(it.uint32)

proc onShardSubscribed*(self: ShardMonitor, shard: uint16) =
  self.subscribedShards.incl(shard)

proc onShardUnSubscribed*(self: ShardMonitor, shard: uint16) =
  self.subscribedShards.excl(shard)

proc onTopicSubscribed*(self: ShardMonitor, topic: PubsubTopic) =
  let shard = RelayShard.parse(topic).valueOr:
    error "Invalid pubsub topic in onTopicSubscribed", error = error
    return
  self.onShardSubscribed(shard.shardId)

proc onTopicUnSubscribed*(self: ShardMonitor, topic: PubsubTopic) =
  let shard = RelayShard.parse(topic).valueOr:
    error "Invalid pubsub topic in onTopicUnSubscribed", error = error
    return
  self.onShardUnSubscribed(shard.shardId)

proc getShardsGetter*(self: ShardMonitor): ShardsGetter =
  return proc(): seq[uint16] =
    return self.getSubscribedShards()

{.pop.}
