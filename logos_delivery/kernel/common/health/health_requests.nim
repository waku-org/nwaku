import brokers/request_broker

import logos_delivery/kernel/common/health/connection_status
import
  logos_delivery/kernel/[
    common/health/protocol_health,
    common/health/topic_health,
    common/health/health_report,
  ]
import logos_delivery/kernel/[common/topics/content_topic, common/topics/pubsub_topic]
import logos_delivery/kernel/[common/health/protocol_health]
export protocol_health, topic_health

# Get the overall node connectivity status
RequestBroker(sync):
  type RequestConnectionStatus* = object
    connectionStatus*: ConnectionStatus

# Get the health status of a set of content topics
RequestBroker(sync):
  type RequestContentTopicsHealth* = object
    contentTopicHealth*: seq[tuple[topic: ContentTopic, health: TopicHealth]]

  proc signature(topics: seq[ContentTopic]): Result[RequestContentTopicsHealth, string]

# Get a consolidated node health report
RequestBroker:
  type RequestHealthReport* = object
    healthReport*: HealthReport

# Get the health status of a set of shards (pubsub topics)
RequestBroker(sync):
  type RequestShardTopicsHealth* = object
    topicHealth*: seq[tuple[topic: PubsubTopic, health: TopicHealth]]

  proc signature(topics: seq[PubsubTopic]): Result[RequestShardTopicsHealth, string]

# Get the health status of a mounted protocol
RequestBroker:
  type RequestProtocolHealth* = object
    healthStatus*: ProtocolHealth

  proc signature(protocol: ProtocolName): Future[Result[RequestProtocolHealth, string]]

# Get edge filter health for a single shard (set when edge mode is active)
RequestBroker(sync):
  type RequestEdgeShardHealth* = object
    health*: TopicHealth

  proc signature(shard: PubsubTopic): Result[RequestEdgeShardHealth, string]

# Get edge filter confirmed peer count (set when edge mode is active)
RequestBroker(sync):
  type RequestEdgeFilterPeerCount* = object
    peerCount*: int
