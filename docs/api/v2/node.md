# Waku APIs

## Nim API

The Nim Waku API consist of a set of methods opearting on the Waku Node object.
Some of them have different arity depending on what privacy/bandwidth trade-off
the consumer wants to make. These methods are:

1. **Init** - create a node.
2. **Start** - start a created node.
3. **Subscribe** - to a topic or a specific content filter.
4. **Unsubscribe** - to a topic or a specific content filter.
5. **Publish** - to a topic, or a topic and a specific content filter.
6. **Query** - for historical messages.
7. **Info** - to get information about the node.
8. **Resume** - to retrieve and persist the message history since the node's last online time.

```Nim
proc init*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none[ValidIpAddress](), extPort = none[Port]()): T =
  ## Creates a Waku Node.
  ##
  ## Status: Implemented.

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node.
  ##
  ## Status: Implemented.

proc subscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.

proc subscribe*(node: WakuNode, request: FilterRequest, handler: ContentFilterHandler) {.async, gcsafe.} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  ## FilterHandler is a method that takes a MessagePush.
  ##
  ## Status: Implemented.

proc unsubscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Unsubscribes a handler from a PubSub topic.
  ##
  ## Status: Implemented.

proc unsubscribeAll*(node: WakuNode, topic: Topic) =
  ## Unsubscribes all handlers registered on a specific PubSub topic.
  ##
  ## Status: Implemented.

proc unsubscribe*(w: WakuNode, contentFilter: ContentFilter) =
  ## Unsubscribe from a content filter.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

proc publish*(node: WakuNode, topic: Topic, message: WakuMessage) =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
  ##
  ## Status: Implemented.

proc query*(w: WakuNode, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  ## Queries known nodes for historical messages. Triggers the handler whenever a response is received.
  ## QueryHandlerFunc is a method that takes a HistoryResponse.
  ##
  ## Status: Implemented.

proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.
  ##
  ## Status: Implemented.
  ##

proc resume*(node: WakuNode, peerList: Option[seq[PeerInfo]]) =
  ## Retrieves and persists the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online. 
  ## It requires the waku node to have the store protocol mounted in the full mode (i.e., persisting messages).
  ## `peerList` indicates the list of peers to query from.
  ## The history is fetched from all available peers in this list and then consolidated into one deduplicated list.
  ## If no peerList is passed, the history is fetched from one of the known peers. 
  ## It retrieves the history successfully given that the dialed peer has been online during the queried time window.
  ##
  ## Status: Implemented.
  ##
```

## JSON RPC

TODO To specify


## REST API

[Here](./rest-api.md) you can find more details on the Node HTTP REST API.
