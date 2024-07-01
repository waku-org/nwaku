{.used.}

import std/[options], testutils/unittests, results

import waku/waku_core/topics/pubsub_topic, ../../testlib/[wakucore]

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

suite "Automatic Sharding Mechanics":
  test "Shard Selection Algorithm":
    let
      topic1 = NsPubsubTopic.parseNamedSharding("/waku/2/xxx").get()
      topic2 = NsPubsubTopic.parseNamedSharding("/waku/2/123").get()
      topic3 = NsPubsubTopic.parseNamedSharding("/waku/2/xxx123").get()

    check:
      # topic1.shardId == 1
      # topic1.clusterId == 0
      topic1 == NsPubsubTopic.staticSharding(0, 1)
      # topic2.shardId == 1
      # topic2.clusterId == 0
      topic2 == NsPubsubTopic.staticSharding(0, 1)
      # topic3.shardId == 1
      # topic3.clusterId == 0
      topic3 == NsPubsubTopic.staticSharding(0, 1)

  test "Shard Selection Algorithm without topicName":
    let topicResult = NsPubsubTopic.parseNamedSharding("/waku/2/")

    check:
      topicResult.isErr()
