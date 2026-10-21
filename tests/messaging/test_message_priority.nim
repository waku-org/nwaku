{.used.}

import chronicles, results, chronos, testutils/unittests, brokers/broker_context

import
  logos_delivery/api/types,
  logos_delivery/waku/requests/node_requests,
  logos_delivery/waku/waku_core/topics,
  logos_delivery/messaging/delivery_service/send_service/delivery_task

const Topic = ContentTopic("/priority/1/test/proto")

suite "MessagePriority":
  test "an envelope defaults to Medium":
    check MessageEnvelope.init(Topic, "payload").priority == MessagePriority.Medium

  test "an explicit priority is kept on the envelope":
    check MessageEnvelope.init(Topic, "payload", priority = MessagePriority.High).priority ==
      MessagePriority.High

  test "parseMessagePriority accepts low|medium|high, rejects others":
    check:
      parseMessagePriority("Low").get() == MessagePriority.Low
      parseMessagePriority("medium").get() == MessagePriority.Medium
      parseMessagePriority("HIGH").get() == MessagePriority.High
      parseMessagePriority("urgent").isErr()

  test "the priority reaches the DeliveryTask":
    let ctx = NewBrokerContext()
    RequestRelayShard
      .setProvider(
        ctx,
        proc(
            pubsubTopic: Opt[PubsubTopic], contentTopic: ContentTopic
        ): Result[RequestRelayShard, string] =
          return ok(RequestRelayShard(relayShard: RelayShard(clusterId: 0, shardId: 0))),
      )
      .expect("provider set")
    defer:
      RequestRelayShard.clearProvider(ctx)

    let requestId = RequestId("req")
    let defaulted =
      DeliveryTask.new(requestId, MessageEnvelope.init(Topic, "a"), ctx).expect("task")
    let high = DeliveryTask
      .new(
        requestId,
        MessageEnvelope.init(Topic, "a", priority = MessagePriority.High),
        ctx,
      )
      .expect("task")
    check:
      defaulted.priority == MessagePriority.Medium
      high.priority == MessagePriority.High
