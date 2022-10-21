# Overview: running a nwaku node

This guide provides on overview for newcomers
on how to build and run a nwaku node
for the most common use cases.
For a more advanced configuration see our [configuration guides](./how-to/configure.md)

To set up a nwaku node on a DigitalOcean droplet,
refer to our [quickstart guide for droplets](./droplet-quickstart.md).
If you prefer running nwaku in Docker container,
see our [Docker guide](./docker-quickstart.md).

## 1. Build

[Build the nwaku node](./how-to/build.md)
or download a precompiled binary from our [releases page](https://github.com/status-im/nwaku/releases).
Docker images are published to [statusteam/nim-waku](https://hub.docker.com/r/statusteam/nim-waku/tags) on Docker Hub.
See our [Docker quickstart guide](./docker-quickstart.md) to run nwaku in a Docker container.

## 2. Run

[Run the nwaku node](./how-to/run.md) using a default or common configuration
or [configure](./how-to/configure.md) the node for more advanced use cases.

[Connect](./how-to/connect.md) the nwaku node to other peers to start communicating.

## 3. Interact

A running nwaku node can be interacted with using the [Waku v2 JSON RPC API](https://rfc.vac.dev/spec/16/).

> **Note:** Private and Admin API functionality are disabled by default.
To configure a nwaku node with these enabled,
use the `--rpc-admin:true` and `--rpc-private:true` CLI options.

```bash
curl -d '{"jsonrpc":"2.0","method":"get_waku_v2_debug_v1_info","params":[],"id":1}' -H 'Content-Type: application/json' localhost:8546 -s | jq
```


Or using the [Waku v2 HTTP REST API](../api/v2/rest-api.md):

> **Note:** REST API functionality is in ALPHA and therefore it is disabled by default. To configure a nwaku node with this enabled, use the `--rest:true` CLI option.


```bash
curl http://localhost:8546/debug/v1/info -s | jq
```
