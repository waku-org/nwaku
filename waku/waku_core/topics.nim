import
  ./topics/content_topic,
  ./topics/pubsub_topic,
  ./topics/sharding

export
  content_topic,
  pubsub_topic,
  sharding

type
  SubscriptionKind* = enum ContentSub, ContentUnsub, PubsubSub, PubsubUnsub
  SubscriptionEvent* = object
    case kind*: SubscriptionKind
      of PubsubSub:  pubsubSub*:  string
      of ContentSub: contentSub*: string
      of PubsubUnsub:  pubsubUnsub*:  string
      of ContentUnsub: contentUnsub*: string