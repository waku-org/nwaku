import std/[options, tables], testutils/unittests

import
  ../../../../waku/waku_core/topics,
  ../../testlib/[wakucore, tables, testutils, simple_mock]

suite "Autosharding":
  const
    pubsubTopic04 = "/waku/2/rs/0/4"
    pubsubTopic13 = "/waku/2/rs/1/3"
    contentTopicShort = "/toychat/2/huilong/proto"
    contentTopicFull = "/0/toychat/2/huilong/proto"
    contentTopicInvalid = "/1/toychat/2/huilong/proto"

  suite "getGenZeroShard":
    test "Generate Gen0 Shard":
      # Given two valid topics
      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
        nsContentTopic2 = NsContentTopic.parse(contentTopicFull).value()

      # When we generate a gen0 shard from them
      let
        nsPubsubTopic1 = getGenZeroShard(nsContentTopic1, GenerationZeroShardsCount)
        nsPubsubTopic2 = getGenZeroShard(nsContentTopic2, GenerationZeroShardsCount)

      # Then the generated shards are valid
      check:
        nsPubsubTopic1 == NsPubsubTopic.staticSharding(ClusterId, 3)
        nsPubsubTopic2 == NsPubsubTopic.staticSharding(ClusterId, 3)

  suite "getShard from NsContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      # When we get a shard from a topic without generation
      let nsPubsubTopic = getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==0":
      # When we get a shard from a gen0 topic
      let nsPubsubTopic = getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==other":
      # When we get a shard from ain invalid content topic
      let nsPubsubTopic = getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.error() == "Generation > 0 are not supported yet"

  suite "getShard from ContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      # When we get a shard from it
      let nsPubsubTopic = getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==0":
      # When we get a shard from it
      let nsPubsubTopic = getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.value() == NsPubsubTopic.staticSharding(ClusterId, 3)

    test "Generate Gen0 Shard with topic.generation==other":
      # When we get a shard from it
      let nsPubsubTopic = getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        nsPubsubTopic.error() == "Generation > 0 are not supported yet"

    test "Generate Gen0 Shard invalid topic":
      # When we get a shard from it
      let nsPubsubTopic = getShard("invalid")

      # Then the generated shard is valid
      check:
        nsPubsubTopic.error() == "invalid format: topic must start with slash"

  suite "parseSharding":
    test "contentTopics is ContentTopic":
      # When calling with contentTopic as string
      let topicMap = parseSharding(some(pubsubTopic04), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort]}

    test "contentTopics is seq[ContentTopic]":
      # When calling with contentTopic as string seq
      let
        topicMap =
          parseSharding(some(pubsubTopic04), @[contentTopicShort, "/0/foo/1/bar/proto"])

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort, "/0/foo/1/bar/proto"]}

    test "pubsubTopic is none":
      # When calling with pubsubTopic as none
      let topicMap = parseSharding(PubsubTopic.none(), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic13: @[contentTopicShort]}

    test "content parse error":
      # When calling with pubsubTopic as none with invalid content
      let topicMap = parseSharding(PubsubTopic.none(), "invalid")

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse content topic: invalid format: topic must start with slash"

    test "pubsubTopic parse error":
      # When calling with pubsubTopic as none with invalid content
      let topicMap = parseSharding(some("invalid"), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse pubsub topic: invalid format: must start with /waku/2"

    test "pubsubTopic getShard error":
      # When calling with pubsubTopic as none with invalid content
      let topicMap = parseSharding(PubsubTopic.none(), contentTopicInvalid)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot autoshard content topic: Generation > 0 are not supported yet"

    test "catchable error on add to topicMap":
      # Given the sequence.add function returns a CatchableError
      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
        nsContentTopic2 = NsContentTopic.parse(contentTopicFull).value()

      type
        SeqNsContentTopicAdd =
          proc(x: var seq[NsContentTopic], y: openArray[NsContentTopic]) {.
            noSideEffect
          .}
          # NsContentTopicAdd =
          #   proc(x: var seq[NsContentTopic], y: sink NsContentTopic) {.noSideEffect.}

      #[
      system.add = $X [add]
      original = $original [$X]
      backup = $backup [$X]
      ]#

      let original: SeqNsContentTopicAdd = system.add
      let backup: SeqNsContentTopicAdd = system.add
      let
        # oAddr = addr(original)
        oUnsafeAddr = unsafeAddr(original)

      echo type(original)
      echo type(oUnsafeAddr)
      echo repr(oUnsafeAddr)
      echo repr(oUnsafeAddr[])

      var a: seq[NsContentTopic]
      let b: NsContentTopic = nsContentTopic1
      var myAdd = getProc(add, var string, string)

      var s: seq[NsContentTopic]
      echo s
      oUnsafeAddr[](s, @[nsContentTopic1])
      echo s
      add(s, @[nsContentTopic2])
      echo s

      proc mocked(x: var seq[NsContentTopic], y: openArray[NsContentTopic]) =
        raise newException(ValueError, "mocked")

      mockImpl(oUnsafeAddr, cast[pointer](mocked))

        # proc mocked(x: var seq[NsContentTopic], y: sink NsContentTopic) =
        #   raise newException(ValueError, "mocked")

      # # ambiguous identifier 'add' -- use one of the following:

      # # system.add: proc (x: var seq[T], y: sink T){.noSideEffect.}
      # # system.add: proc (x: var string, y: char){.noSideEffect.}
      # # system.add: proc (x: var seq[T], y: openArray[T]){.noSideEffect.}
      # # system.add: proc (x: var string, y: string){.noSideEffect, gcsafe.}
      # # system.add: proc (x: var string, y: cstring){.noSideEffect, gcsafe.}
      # # 'add' is a built-in and cannot be used as a first-class procedure

      # # add(TYPEHERE) maybe? same way we do none(MyType)
      # mock(original):
      #   proc mockedAdd(x: var seq[NsContentTopic], y: sink NsContentTopic) =
      #     raise newException(ValueError, "mockedAdd")

      #   mockedAdd

      # # When calling the function
      # let topicMap = parseSharding(some(pubsubTopic04), contentTopicShort)

      # # Then the result 
      # check:
      #   topicMap ==
      #     Result[Table[NsPubsubTopic, seq[NsContentTopic]], string].error("mockedAdd")

      # # Cleanup
      # mock(original):
      #   backup
