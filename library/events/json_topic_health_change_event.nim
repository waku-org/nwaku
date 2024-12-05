import system, results, std/json
import stew/byteutils
import ../../waku/common/base64, ./json_base_event
import ../../waku/node/peer_manager/topic_health

type JsonTopicHealthChangeEvent* = ref object of JsonEvent
  pubsubTopic*: string
  topicHealth*: TopicHealth

proc new*(
    T: type JsonTopicHealthChangeEvent, pubsubTopic: string, topicHealth: TopicHealth
): T =
  # Returns a TopicHealthChange event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  return JsonTopicHealthChangeEvent(
    eventType: "topic_health_change", pubsubTopic: pubsubTopic, topicHealth: topicHealth
  )

method `$`*(jsonTopicHealthChange: JsonTopicHealthChangeEvent): string =
  $(%*jsonTopicHealthChange)
