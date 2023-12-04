proc getPubsunTopic*(contentTopicName: string): string =
  return "/waku/2/$contentTopicName"


const
  CURRENT* = getPubsunTopic("test")
  CURRENT_NESTED* = getPubsunTopic("test/nested")
  SHARDING* = getPubsunTopic("waku-9_shard-0")
  PLAIN* = "test"
  LEGACY* = "/waku/1/test"
  LEGACY_NESTED* = "/waku/1/test/nested"
  LEGACY_ENCODING* = "/waku/1/test/proto"
