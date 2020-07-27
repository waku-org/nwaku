# Waku APIs

## Nim API

### WakuSub API

This is an internal API to be used by the Waku API. It is practically a small
layer above GossipSub. And possibly a request/response libp2p protocol.

```Nim
# TODO: Some init call to set things up?
method publish*(w: WakuSub, topic: string, data: seq[byte]) {.async.}
method subscribe*(w: WakuSub, topic: string, handler: TopicHandler) {.async.}
method unsubscribe*(w: WakuSub, topics: seq[TopicPair]) {.async.}

# TODO: Calls for non GossipSub communication.
```

### Waku API

This API is very dependend on how the protocol should work for functionality
such as light nodes (no relaying) and nodes that do not want to get messages
from all `WakuTopic`s.

See also issue:
https://github.com/vacp2p/specs/issues/156

For now it is assumed that we will require a seperate request-response protocol
for this, next to the GossipSub domain.

```Nim
## Implemented
##----------------------------------------------------------
type
  WakuNode* = ref object of RootObj
  switch*: Switch
  peerInfo*: PeerInfo
  libp2pTransportLoops*: seq[Future[void]]

proc createWakuNode*(conf: WakuNodeConf): Future[WakuNode] {.async, gcsafe.} =
## Creates the WakuNode.

proc start*(node: WakuNode, conf: WakuNodeConf) {.async.} =
## Starts an already created WakuNode.
##
## When not a light node, this will set up the node to be part of the gossipsub
## network with a subscription to the general Waku Topic.
## When a light node, this will connect to full node peer(s) with provided
## `contentFilter` for the full node to filter on. Currently this means
## `contentTopic`, but this could potentially be `bloomFilter` and other filters
## as well.

## Not yet implemented / under consideration
##----------------------------------------------------------

type
  WakuOptions = object
  # If there are more capabilities than just light node, we can create a
  # capabilities field.
    lightNode: bool
    topics: seq[WakuTopic]
    bloomfilter: Bloom # TODO: No longer needed with Gossip?
    limits: Limits

proc publish(w: WakuNode, topic: WakuTopic, data: seq[byte]): bool
## Publish a message with specified `WakuTopic`.
##
## Both full node and light node can use the GossipSub network to publish.

proc subscribe(w: WakuNode, topics: seq[WakuTopic], handler: WakuHandler): Identifier
## Subscribe to the provided `topics`, handler will be called on receival of
## messages on those topics.
##
## In case of a full node, this will be through the GossipSub network (see,
## subscription in `init`)
## In case of the light node, this will likely be through a separate request
## response network where the full node filters out the messages.

proc unsubscribe(id: Identifier): bool
## Unsubscribe handler for topics.

# Can get rid of the identifiers in subscribe and unsubscribe and track topics +
# handler like in WakuSub, if that is more convenient.

proc setLightNode(isLightNode: bool)
## Change light node setting. This might trigger change in subscriptions from
## the gossip domain to the request response domain and vice versa.

proc setTopicInterest(topics: seq[string])
## Change the topic interests.
# TODO: Only valid if light node?

proc setBloomFilter(topics: seq[string])
## Change the topic interests.
# TODO: Still required if we have gossip?
```

## JSON RPC

**TODO: Data should be RPC Messages / bytes**
**TODO: Enable topic handler**

Call signatures:

```Nim
proc waku_version(): string
proc waku_info(): WakuInfo
proc waku_publish(topic: string, message: string): bool
proc waku_subscribe(topics: seq[string]): Identifier
proc waku_unsubscribe(id: Identifier): bool

# TODO: Do we still want to be able to pull for data also?
# E.g. a getTopicsMessages(topics: seq[string])?

proc waku_setLightNode(isLightNode: bool)
proc waku_setTopicInterest(topics: seq[string])
proc waku_setBloomFilter(topics: seq[string])
```
