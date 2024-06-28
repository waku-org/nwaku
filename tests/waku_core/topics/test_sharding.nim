import std/[options, tables], testutils/unittests

import waku_core/topics, ../../testlib/[wakucore, tables, testutils]

const GenerationZeroShardsCount = 8
const ClusterId = 1

suite "Autosharding":
  const
    pubsubTopic04 = "/waku/2/rs/0/4"
    pubsubTopic13 = "/waku/2/rs/1/3"
    contentTopicShort = "/toychat/2/huilong/proto"
    contentTopicFull = "/0/toychat/2/huilong/proto"
    contentTopicShort2 = "/toychat2/2/huilong/proto"
    contentTopicFull2 = "/0/toychat2/2/huilong/proto"
    contentTopicShort3 = "/toychat/2/huilong/proto2"
    contentTopicFull3 = "/0/toychat/2/huilong/proto2"
    contentTopicShort4 = "/toychat/4/huilong/proto2"
    contentTopicFull4 = "/0/toychat/4/huilong/proto2"
    contentTopicFull5 = "/1/toychat/2/huilong/proto"
    contentTopicFull6 = "/1/toychat2/2/huilong/proto"
    contentTopicInvalid = "/1/toychat/2/huilong/proto"

  suite "getGenZeroShard":
    test "Generate Gen0 Shard":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)

      # Given two valid topics
      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
        nsContentTopic2 = NsContentTopic.parse(contentTopicFull).value()
        nsContentTopic3 = NsContentTopic.parse(contentTopicShort2).value()
        nsContentTopic4 = NsContentTopic.parse(contentTopicFull2).value()
        nsContentTopic5 = NsContentTopic.parse(contentTopicShort3).value()
        nsContentTopic6 = NsContentTopic.parse(contentTopicFull3).value()
        nsContentTopic7 = NsContentTopic.parse(contentTopicShort3).value()
        nsContentTopic8 = NsContentTopic.parse(contentTopicFull3).value()
        nsContentTopic9 = NsContentTopic.parse(contentTopicFull4).value()
        nsContentTopic10 = NsContentTopic.parse(contentTopicFull5).value()

      # When we generate a gen0 shard from them
      let
        nsPubsubTopic1 =
          sharding.getGenZeroShard(nsContentTopic1, GenerationZeroShardsCount)
        nsPubsubTopic2 =
          sharding.getGenZeroShard(nsContentTopic2, GenerationZeroShardsCount)
        nsPubsubTopic3 =
          sharding.getGenZeroShard(nsContentTopic3, GenerationZeroShardsCount)
        nsPubsubTopic4 =
          sharding.getGenZeroShard(nsContentTopic4, GenerationZeroShardsCount)
        nsPubsubTopic5 =
          sharding.getGenZeroShard(nsContentTopic5, GenerationZeroShardsCount)
        nsPubsubTopic6 =
          sharding.getGenZeroShard(nsContentTopic6, GenerationZeroShardsCount)
        nsPubsubTopic7 =
          sharding.getGenZeroShard(nsContentTopic7, GenerationZeroShardsCount)
        nsPubsubTopic8 =
          sharding.getGenZeroShard(nsContentTopic8, GenerationZeroShardsCount)
        nsPubsubTopic9 =
          sharding.getGenZeroShard(nsContentTopic9, GenerationZeroShardsCount)
        nsPubsubTopic10 =
          sharding.getGenZeroShard(nsContentTopic10, GenerationZeroShardsCount)

      # Then the generated shards are valid
      check:
        nsPubsubTopic1 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic2 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic3 == NsPubsubTopic.staticSharding(ClusterId, 6)
        nsPubsubTopic4 == NsPubsubTopic.staticSharding(ClusterId, 6)
        nsPubsubTopic5 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic6 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic7 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic8 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic9 == NsPubsubTopic.staticSharding(ClusterId, 7)
        nsPubsubTopic10 == NsPubsubTopic.staticSharding(ClusterId, 3)

  suite "getShard from NsContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)

      # When we get a shard from a topic without generation
      let nsPubsubTopic = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from a gen0 topic
      let nsPubsubTopic = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from ain invalid content topic
      let nsPubsubTopic = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.error() == "Generation > 0 are not supported yet"

  suite "getShard from ContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let nsPubsubTopic = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let nsPubsubTopic = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let nsPubsubTopic = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.error() == "Generation > 0 are not supported yet"

    test "Generate Gen0 Shard invalid topic":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let nsPubsubTopic = sharding.getShard("invalid")

      # Then the generated shard is valid
      check:
        nsPubsubTopic.error() == "invalid format: topic must start with slash"

  suite "parseSharding":
    test "contentTopics is ContentTopic":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with contentTopic as string
      let topicMap = sharding.parseSharding(some(pubsubTopic04), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort]}

    test "contentTopics is seq[ContentTopic]":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with contentTopic as string seq
      let topicMap = sharding.parseSharding(
        some(pubsubTopic04), @[contentTopicShort, "/0/foo/1/bar/proto"]
      )

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort, "/0/foo/1/bar/proto"]}

    test "pubsubTopic is none":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none
      let topicMap = sharding.parseSharding(PubsubTopic.none(), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic13: @[contentTopicShort]}

    test "content parse error":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(PubsubTopic.none(), "invalid")

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse content topic: invalid format: topic must start with slash"

    test "pubsubTopic parse error":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(some("invalid"), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse pubsub topic: invalid format: must start with /waku/2"

    test "pubsubTopic getShard error":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(PubsubTopic.none(), contentTopicInvalid)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot autoshard content topic: Generation > 0 are not supported yet"

    xtest "catchable error on add to topicMap":
      # TODO: Trigger a CatchableError or mock
      discard
