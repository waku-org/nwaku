# Dingpu testnet

## Basic chat usage

> If historical messaging is desired, the chat app requires that the remote peer specified in `storenode` option supports the WakuStore protocol. For the current cluster node deployed as part of Dingpu this is already the case.

Start two chat apps:

```
./build/chat2 --ports-shift:0 --storenode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
./build/chat2 --ports-shift:1 --storenode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```

Type `/connect` then paste address of other node.

Then type messages to publish.

## Dingpu cluster node

```
/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```
