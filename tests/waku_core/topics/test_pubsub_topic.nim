{.used.}

import std/[options], testutils/unittests, results

import ../../../../waku/[waku_core/topics/pubsub_topic], ../../testlib/[wakucore]

suite "Static Sharding Functionality":
  test "Shard Cluster Identification":
    let topic = NsPubsubTopic.parseStaticSharding("/waku/2/rs/0/1").get()
    check:
      topic.clusterId == 0
      topic.shardId == 1
      topic == NsPubsubTopic.staticSharding(0, 1)

  test "Pubsub Topic Naming Compliance":
    let topic = NsPubsubTopic.staticSharding(0, 1)
    check:
      topic.clusterId == 0
      topic.shardId == 1
      topic == "/waku/2/rs/0/1"
