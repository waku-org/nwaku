# Dingpu testnet

*NOTE: Some of these addresses might change. To get the latest, please see `curl -s https://fleets.status.im | jq '.fleets["wakuv2.test"]'`*

## Basic chat usage

> If historical messaging is desired, the chat app requires that the remote peer specified in `storenode` option supports the WakuStore protocol. For the current cluster node deployed as part of Dingpu this is already the case.

Start two chat apps:

```
./build/chat2 --ports-shift:0 --storenode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS --staticnode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
./build/chat2 --ports-shift:1 --storenode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS --staticnode:/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```

By specifying `staticnode` it connects to that node subscribes to the `waku` topic. This ensures messages are relayed properly.

Then type messages to publish.

## Interactively add a node

There is also an interactive mode. Type `/connect` then paste address of other node. However, this currently has some timing issues with mesh not being updated, so it is adviced not to use this until this has been addressed. See https://github.com/status-im/nim-waku/issues/231

## Dingpu cluster node

```
/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```

## Run a node

To just run a node and not interact on the chat it is enough to run `wakunode2`:
```
./build/wakunode2 --staticnode:<multiaddr>
```

You can also run the `wakubridge` process, which runs both a Waku v1 and Waku v2
node. Currently, it has the same effect as running a `wakunode` and `wakunode2`
process separately, but bridging functionality will be added later to this
application.

```
./build/wakubridge --staticnodev2:<multiaddr> --fleetv1:test
```
