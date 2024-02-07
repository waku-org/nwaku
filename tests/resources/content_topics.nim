proc getContentTopic*(applicationName: string, applicationVersion: int, contentTopicName: string, encoding: string): string =
  return "/$applicationName/$applicationVersion/$contentTopicName/$enconding"


const
  CURRENT* = getContentTopic("application", 1, "content-topic", "proto")
  TESTNET* = getContentTopic("toychat", 2, "huilong", "proto")
  PLAIN* = "test"
