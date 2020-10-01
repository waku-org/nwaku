# Nangang Test

Nangang is the first internal testnet. See
https://github.com/vacp2p/research/issues/43 for more.

## How to

Build:

```
# make wakunode2 is run as part of scripts2 target
make scripts2
```

Run two nodes and connect them:

```
# Starts listening on 60000 with RPC server on 8545.
# Note the "listening on address" in logs.
./build/wakunode2 --ports-shift:0

# Run another node with staticnode argument
./build/wakunode2 --ports-shift:1 --staticnode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp
```

You should see your nodes connecting.

Do basic RPC calls:

```
./build/rpc_subscribe 8545
./build/rpc_subscribe 8546
./build/rpc_publish 8545 # enter your message in STDIN
```

You should see other node receive something.

## Nangang cluster node

```
/ip4/134.209.139.210/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS
```
