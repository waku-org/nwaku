## Waku layer API — content-topic subscription operations.
##
## These wrap the node's `SubscriptionManager`, which resolves each content
## topic to its autosharding shard. They give the layers above (messaging) a
## kernel-level entry point so they never reach into `waku` internals.
{.push raises: [].}

import std/sets
import results

import logos_delivery/kernel/kernel
import
  logos_delivery/kernel/
    [base/topics/content_topic, base/topics/pubsub_topic, subscription_manager]
proc subscribe*(self: Kernel, contentTopic: ContentTopic): Result[void, string] =
  ## Subscribes to `contentTopic`, resolving its shard via autosharding.
  return self.subscriptionManager.subscribe(contentTopic)

proc unsubscribe*(self: Kernel, contentTopic: ContentTopic): Result[void, string] =
  ## Unsubscribes from `contentTopic`, resolving its shard via autosharding.
  return self.subscriptionManager.unsubscribe(contentTopic)

proc isSubscribed*(self: Kernel, contentTopic: ContentTopic): Result[bool, string] =
  ## True if the node already subscribes to `contentTopic`.
  return self.subscriptionManager.isSubscribed(contentTopic)

proc isContentSubscribed*(
    self: Kernel, shard: PubsubTopic, contentTopic: ContentTopic
): bool =
  ## True if `contentTopic` is subscribed on the given `shard` (pubsub topic).
  return self.subscriptionManager.isContentSubscribed(shard, contentTopic)

proc isAutoshardingConfigured*(self: Kernel): bool =
  ## True when content topics resolve to shards (a network preset or
  ## --num-shards-in-network is set).
  return self.wakuAutoSharding.isSome()

proc subscribedContentTopics*(self: Kernel): seq[(PubsubTopic, HashSet[ContentTopic])] =
  ## Snapshot of every shard with its non-empty content-topic set.
  var res: seq[(PubsubTopic, HashSet[ContentTopic])]
  for shard, contentTopics in self.subscriptionManager.subscribedContentTopics:
    res.add((shard, contentTopics))
  return res
