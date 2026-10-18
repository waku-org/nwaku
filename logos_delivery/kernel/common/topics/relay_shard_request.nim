import results, brokers/[request_broker, multi_request_broker]
import logos_delivery/kernel/[common/topics/content_topic, common/topics/pubsub_topic]
RequestBroker(sync):
  type RequestRelayShard* = object
    relayShard*: RelayShard

  proc signature(
    pubsubTopic: Opt[PubsubTopic], contentTopic: ContentTopic
  ): Result[RequestRelayShard, string]
