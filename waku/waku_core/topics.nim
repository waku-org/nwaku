import ./topics/content_topic, ./topics/pubsub_topic, ./topics/sharding

export content_topic, pubsub_topic, sharding

type
  SubscriptionKind* = enum
    Subscribe
    Unsubscribe

  SubscriptionEvent* =
    tuple[kind: SubscriptionKind, pubsubTopic: string, contentTopics: seq[string]]
