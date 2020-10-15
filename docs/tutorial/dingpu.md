# Dingpu testnet

## Basic chat usage

> If historical messaging is desired, the chat app requires that the remote peer specified in `storenode` option supports the WakuStore protocol. For the current cluster node deployed as part of Dingpu this is already the case.

Start two chat apps:

```
./build/chat2 --ports-shift:0 --storenode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS --staticnode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
./build/chat2 --ports-shift:1 --storenode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS --staticnode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```

By specifying `staticnode` it connects to that node subscribes to the `waku` topic. This ensures messages are relayed properly.

Then type messages to publish.

## Dingpu cluster node

```
/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```
## Interactively add a node

There is also an interactive mode. Type `/connect` then paste address of other node. However, this currently has some timing issues with mesh not being updated, so it is adviced not to use this until this has been addressed. See https://github.com/status-im/nim-waku/issues/231
