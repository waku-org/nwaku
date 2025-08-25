{.push raises: [].}

import std/sets, sequtils, results, chronicles
import ../waku_core/topics/pubsub_topic

type ShardsGetter* = proc(): seq[uint16] {.gcsafe, raises: [].}

type ShardsSubscriptionMonitor* = ref object of RootObj
  subscribedShards: HashSet[uint16]

proc new*(T: type ShardsSubscriptionMonitor): T =
  let sm = ShardsSubscriptionMonitor(subscribedShards: initHashSet[uint16]())
  return sm

proc getSubscribedShards*(self: ShardsSubscriptionMonitor): seq[uint16] =
  return toseq(self.subscribedShards)

#This is implemented temporarily until all shard related refs are moved to uint16
proc getSubscribedShardsUint32*(self: ShardsSubscriptionMonitor): seq[uint32] =
  return self.subscribedShards.mapIt(it.uint32)

proc onShardSubscribed*(self: ShardsSubscriptionMonitor, shard: uint16) =
  self.subscribedShards.incl(shard)

proc onShardUnSubscribed*(self: ShardsSubscriptionMonitor, shard: uint16) =
  self.subscribedShards.excl(shard)

proc onTopicSubscribed*(self: ShardsSubscriptionMonitor, topic: PubsubTopic) =
  let shard = RelayShard.parse(topic).valueOr:
    error "Invalid pubsub topic", error = error
    return
  self.onShardSubscribed(shard.shardId)

proc onTopicUnSubscribed*(self: ShardsSubscriptionMonitor, topic: PubsubTopic) =
  let shard = RelayShard.parse(topic).valueOr:
    error "Invalid pubsub topic", error = error
    return
  self.onShardUnSubscribed(shard.shardId)

proc getShardsGetter*(self: ShardsSubscriptionMonitor): ShardsGetter =
  return proc(): seq[uint16] =
    return self.getSubscribedShards()

{.pop.}
