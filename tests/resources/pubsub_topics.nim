import std/strformat

proc getPubsubTopic*(pubsubTopicName: string): string =
  return fmt"/waku/2/{pubsubTopicName}"


const
  CURRENT* = getPubsubTopic("test")
  CURRENT_NESTED* = getPubsubTopic("test/nested")
  SHARDING* = getPubsubTopic("waku-9_shard-0")
  PLAIN* = "test"
  LEGACY* = "/waku/1/test"
  LEGACY_NESTED* = "/waku/1/test/nested"
  LEGACY_ENCODING* = "/waku/1/test/proto"
