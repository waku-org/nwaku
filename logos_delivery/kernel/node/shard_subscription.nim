{.push raises: [].}

import std/sets
import logos_delivery/kernel/core/[ topics/content_topic, topics/content_topic]

type ShardSubscription* = object
  contentTopics*: HashSet[ContentTopic]
  directShardSub*: bool
    ## shard subscribed directly (PubsubSub), independent of content-topic interest

{.pop.}
