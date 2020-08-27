# Waku APIs

## Nim API

The Nim Waku API consist of five methods. Some of them have different arity
depending on what privacy/bandwidth trade-off the consumer wants to make. These
five method are:

1. **Init** - create and start a node.
2. **Subscribe** - to a topic or a specific content filter.
3. **Unsubscribe** - to a topic or a specific content filter.
4. **Publish** - to a topic, or a topic and a specific content filter.
5. **Query** - for historical messages.

```Nim
proc init*(T: type WakuNode, conf: WakuNodeConf): Future[T]
  ## Creates and starts a Waku node.
  ##
  ## Status: Implemented.

method subscribe*(w: WakuNode, topic: Topic, handler: TopicHandler)
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be read as a WakuMessage.
  ## Status: Implemented.

method subscribe*(w: WakuNode, contentFilter: ContentFilter, handler: ContentFilterHandler)
  ## Subscribes to a ContentFilter. Triggers handler when receiving messages on
  ## this content filter. ContentFilter is a method that takes some content
  ## filter, specifically with `ContentTopic`, and a `Message`. The `Message`
  ## has to match the `ContentTopic`.

  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_filter` and `subscribe` above.

method unsubscribe*(w: WakuNode, topic: Topic)
  ## Unsubscribe from a topic.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

method unsubscribe*(w: WakuNode, contentFilter: ContentFilter)
  ## Unsubscribe from a content filter.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

method publish*(w: WakuNode, topic: Topic, message: Message)
  ## Publish a `Message` to a PubSub topic.
  ##
  ## Status: Partially implemented.
  ## TODO WakuMessage OR seq[byte]. NOT PubSub Message.

method publish*(w: WakuNode, topic: Topic, contentFilter: ContentFilter, message: Message)
  ## Publish a `Message` to a PubSub topic with a specific content filter.
  ## Currently this means a `contentTopic`.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_relay` and `publish`.
  ## TODO WakuMessage. Ensure content filter is in it.

method query*(w: WakuNode, query: HistoryQuery): HistoryResponse
  ## Queries for historical messages.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_store` and send RPC.
```

## JSON RPC

### TODO To specify
