# Node API

TBD.

*NOTE: Below is a scratch of what the API currently looks like. This will likely change. See https://github.com/status-im/nim-waku/issues/39*

## Nim API

*NOTE: Some of these are currently at the protocol layer rather than than the Node itself.*

```
method publish*(w: WakuSub, topic: string, data: seq[byte]) {.async.}
method subscribe*(w: WakuSub, topic: string, handler: TopicHandler) {.async.}
```

## JSON RPC

**TODO: Data should be RPC Messages / bytes**
**TODO: Enable topic handler**

Call sigs:

```
proc waku_version(): string
proc waku_publish(topic: string, message: string): bool
proc waku_subscribe(topic: string): bool
```
