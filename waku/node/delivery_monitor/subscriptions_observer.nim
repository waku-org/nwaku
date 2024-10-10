import chronicles

type SubscriptionObserver* = ref object of RootObj

method onSubscribe*(
    self: SubscriptionObserver, pubsubTopic: string, contentTopics: seq[string]
) {.base, gcsafe, raises: [].} =
  error "onSubscribe not implemented"

method onUnsubscribe*(
    self: SubscriptionObserver, pubsubTopic: string, contentTopics: seq[string]
) {.base, gcsafe, raises: [].} =
  error "onUnsubscribe not implemented"
