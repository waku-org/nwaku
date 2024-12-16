import ../waku_relay/protocol, ../node/peer_manager/topic_health

type AppCallbacks* = ref object
  relayHandler*: WakuRelayHandler
  topicHealthChangeHandler*: TopicHealthChangeHandler
