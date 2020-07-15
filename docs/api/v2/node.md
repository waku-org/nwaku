# Node API

TBD.

*NOTE: Below is a scratch of what the API currently looks like. This will likely change. See https://github.com/status-im/nim-waku/issues/39*

## Nim API

*NOTE: Some of these are currently at the protocol layer rather than than the Node itself.*

### WakuSub API

```Nim
method publish*(w: WakuSub, topic: string, data: seq[byte]) {.async.}
method subscribe*(w: WakuSub, topic: string, handler: TopicHandler) {.async.}
method unsubscribe*(w: WakuSub, topics: seq[TopicPair]) {.async.}
```

### Waku API

```Nim
proc publish(w: WakuNode, topic: WakuTopic, data: seq[byte]): bool
proc subscribe(w: WakuNode, topics: seq[string], handler: WakuHandler): Identifier
proc unsubscribe(id: Identifier): bool
# Can get rid of the identifiers here and do something like WakuSub.

# TODO: How can these work at all? We can't be selective on this at the level
# of gossipsub.
# Perhaps there is need for another subprotocol (non gossip) for "light" node
# communication?
proc setBloomFilter(topics: seq[string])
proc setTopicInterest(topics: seq[string])
proc setLightNode(isLightNode: bool)
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

# TODO: How can these work at all? We can't be selective on this at the level
# of gossipsub.
# Perhaps there is need for another subprotocol (non gossip) for "light" node
# communication?
proc waku_setBloomFilter(topics: seq[string])
proc waku_setTopicInterest(topics: seq[string])
proc waku_setLightNode(isLightNode: bool)

```
