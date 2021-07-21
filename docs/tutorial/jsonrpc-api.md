# Waku v2 JSON-RPC API Basic Tutorial

## Background

This tutorial provides step-by-step instructions on how to start a `wakunode2` with the [JSON-RPC API](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md) for basic peer-to-peer messaging using publish-subscribe (pubsub) patterns. Libp2p pubsub-functionality is provided in Waku v2 and accessed via the [Relay API](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#relay-api). Debugging methods are accessed via the [Debug API](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#debug-api).

## Setup

Ensure you have built and run `wakunode2` as per [these instructions](https://github.com/status-im/nim-waku).

By default a running `wakunode2` will expose a JSON-RPC API on the localhost (`127.0.0.1`) at port `8545`. It is possible to change this configuration by setting the `rpc-address` and `rpc-port` options when running the node:
```
./build/wakunode2 --rpc-address:127.0.1.1 --rpc-port:8546
```
It is also possible to connect to one of our [testnets](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/dingpu.md) by specifying a `staticnode` when running the node:
```
./build/wakunode2 --staticnode:<multiaddr>
```
where `<multiaddr>` is the multiaddress of a testnet node, e.g. the dingpu cluster node at
```
/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```

## Calling JSON-RPC methods

One way to access JSON-RPC methods is by using the `cURL` command line tool. For example:
```
curl -d '{"jsonrpc":"2.0","id":"id","method":"<method-name>", "params":[<params>]}' --header "Content-Type: application/json" http://localhost:8545
```
where `<method-name>` is the name of the JSON-RPC method to call and `<params>` is a comma-separated `Array` of parameters to pass as arguments to the selected method. This assumes that the API is exposed on the `localhost` at port `8545` (the default configuration). See [this page](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md) for a full list of supported methods and parameters.

## Perform a health check

You can perform a basic health check to verify that the `wakunode2` and API is up and running by calling the [`get_waku_v2_debug_v1_info` method](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#get_waku_v2_debug_v1_info) with no parameters. A successful response contains the node's [`multiaddress`](https://docs.libp2p.io/concepts/addressing/).

### Example request

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "method": "get_waku_v2_debug_v1_info",
  "params": []
}
```

### Example response

The response

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "result": {
    "listenStr": "/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAm9R5sa7ivrCFLvGtLfc6WSyeHjiofdjZSHahJq1andKEG"
  },
  "error": null
}
```
indicates that the `wakunode2` is running and provides its multiaddress.

## Subscribe to a pubsub topic

You can subscribe to pubsub topics by calling the [`post_waku_v2_relay_v1_subscriptions` method](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#post_waku_v2_relay_v1_subscriptions) with an array of topic(s) as parameter. Pubsub topics are in `String` format.

### Example request

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "method": "post_waku_v2_relay_v1_subscriptions",
  "params": [
    [
      "my_topic_1",
      "my_topic_2",
      "my_topic_3"
    ]
  ]
}
```

### Example response

The response

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "result": true,
  "error": null
}
```
indicates that the `wakunode2` successfully subscribed to all three requested topics.

## Publish to a pubsub topic

To publish a message to a pubsub topic, call the [`post_waku_v2_relay_v1_message` method](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#post_waku_v2_relay_v1_message) with the target topic and publishable message as parameters. The message payload must be stringified as a hexadecimal string and wrapped in a [`WakuRelayMessage`](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#wakurelaymessage) `Object`. Besides the published payload, a `WakuRelayMessage` can also contain an optional `contentTopic` that falls outside the scope of this tutorial. See the [`WakuFilter` specification](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-filter.md) for more information.

### Example request

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "method": "post_waku_v2_relay_v1_message",
  "params": [
    "my_topic_1",
    {
      "payload": "0x1a2b3c4d5e6f",
      "timestamp": 1626813243.916377
    }
  ]
}
```

### Example response

The response

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "result": true,
  "error": null
}
```
indicates that the message payload was successfully published to `"my_topic_1"`.

## Read new messages from a subscribed pubsub topic

Use the [`get_waku_v2_relay_v1_messages` method](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#get_waku_v2_relay_v1_messages) to retrieve the messages received on a subscribed pubsub topic. The queried topic is passed as parameter. This will only return new messages received after the last time this method was called. Repeated calls to `get_waku_v2_relay_v1_messages` can therefore be used to continuously poll a topic for new messages.

### Example request

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "method": "get_waku_v2_relay_v1_messages",
  "params": [
    "my_topic_1"
  ]
}
```

### Example response

The response is an `Array` of [`WakuMessage` objects](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#wakumessage).

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "result": [
    {
      "payload": "0xaabbccddeeff",
      "contentTopic": 0,
      "version": 0
    },
    {
      "payload": "0x112233445566",
      "contentTopic": 0,
      "version": 0
    }
  ],
  "error": null
}
```

Calling the same method again returns

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "result": [],
  "error": null
}
```
indicating that no new messages were received on the subscribed topic.

## Unsubscribe from a pubsub topic

To unsubscribe from pubsub topics, call the [`delete_waku_v2_relay_v1_subscriptions` method](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-v2-rpc-api.md#delete_waku_v2_relay_v1_subscriptions) with an array of topic(s) as parameter.

### Example request

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "method": "delete_waku_v2_relay_v1_subscriptions",
  "params": [
    [
      "my_topic_1",
      "my_topic_2"
    ]
  ]
}
```

### Example response

The response

```json
{
  "jsonrpc": "2.0",
  "id": "id",
  "result": true,
  "error": null
}
```
indicates that the `wakunode2` successfully unsubscribed from both topics.
