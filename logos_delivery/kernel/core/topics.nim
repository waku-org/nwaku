type
  SubscriptionKind* = enum
    ContentSub
    ContentUnsub
    PubsubSub
    PubsubUnsub

  SubscriptionEvent* = tuple[kind: SubscriptionKind, topic: string]
