import ../waku_relay

type AppCallbacks* = ref object
  relayHandler*: WakuRelayHandler
  topicHealthChangeHandler*: TopicHealthChangeHandler
