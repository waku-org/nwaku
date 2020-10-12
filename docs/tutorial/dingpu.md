# Dingpu testnet

## Basic chat usage

> The chat app requires that the remote peer connected to is supports the WakuStore protocol. For Dingpu this is already the case.

Start two chat apps:

```
./build/chat2 --ports-shift:0
./build/chat2 --ports-shift:1 --storenode:othernode
```

Type `/connect` then paste address of other node.

Then type messages to publish.

## Dingpu cluster node

```
/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```
