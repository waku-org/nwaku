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
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.

proc subscribe*(w: WakuNode, filter: FilterRequest, handler: FilterHandler) {.async, gcsafe.} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  ## FilterHandler is a method that takes a MessagePush.
  ##
  ## Status: Implemented.

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

method publish*(w: WakuNode, topic: Topic, message: WakuMessage)
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
  ##
  ## Status: Implemented.

method query*(w: WakuNode, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  ## Queries known nodes for historical messages. Triggers the handler whenever a response is received.
  ## QueryHandlerFunc is a method that takes a HistoryResponse.
  ##
  ## Status: Implemented.
```

## JSON RPC

### TODO To specify
