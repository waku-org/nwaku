# Quickstart: running a nwaku node

This guide explains how to build and run a nwaku node
for the most common use cases.
For a more advanced configuration see our [configuration guides](./how-to/configure.md)

## 1. Build

[Build the nwaku node](./how-to/build.md)
or download a precompiled binary from our [releases page](https://github.com/status-im/nwaku/releases).
Docker images are published to [statusteam/nim-waku](https://hub.docker.com/r/statusteam/nim-waku/tags) on DockerHub.

<!-- TODO: more advanced explanation on finding and using docker images -->

## 2. Run

[Run the nwaku node](./how-to/run.md) using a default or common configuration
or [configure](./how-to/configure.md) the node for more advanced use cases.

[Connect](./how-to/connect.md) the nwaku node to other peers to start communicating.

## 3. Interact

A running nwaku node can be interacted with using the [Waku v2 JSON RPC API](https://rfc.vac.dev/spec/16/).

> **Note:** Private and Admin API functionality are disabled by default.
To configure a nwaku node with these enabled,
use the `--rpc-admin:true` and `--rpc-private:true` CLI options.
