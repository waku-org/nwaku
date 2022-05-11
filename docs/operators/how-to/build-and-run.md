# Build and run

Nwaku can be built and run on Linux and macOS.
Windows support is experimental.

## Installing dependencies

Cloning and building nwaku requires the usual developer tools,
such as a C compiler, Make, Bash and Git.

### Linux

On common Linux distributions the dependencies can be installed with

```sh
# Debian and Ubuntu
sudo apt-get install build-essential git

# Fedora
dnf install @development-tools

# Archlinux, using an AUR manager
yourAURmanager -S base-devel
```

### macOS

Assuming you use [Homebrew](https://brew.sh/) to manage packages

```sh
brew install cmake
```

## Building nwaku

### 1. Clone the nwaku repository

```sh
git clone https://github.com/status-im/nwaku
cd nwaku
```

### 2. Make the `wakunode2` target

```sh
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakunode2
```

This will create a `wakunode2` binary in the `./build/` directory.

> **Note:** Building `wakunode2` requires 2GB of RAM.
The build will fail on systems not fulfilling this requirement. 

> Setting up a `wakunode2` on the smallest [digital ocean](https://docs.digitalocean.com/products/droplets/how-to/) droplet, you can either
> * compile on a stronger droplet featuring the same CPU architecture and downgrade after compiling, or
> * activate swap on the smallest droplet, or
> * use Docker.

## Running nwaku

```sh
# Run with default configuration
./build/wakunode2

# See available command line options
./build/wakunode2 --help
```

### Default configuration

By default a nwaku node will:
- generate a new private key and libp2p identities after every restart.
See [this tutorial](./configure-key.md) if you want to generate and configure a persistent private key.
- listen for incoming libp2p connections on the default TCP port (`60000`)
- enable `relay` protocol
- subscribe to the default pubsub topic, namely `/waku/2/default-waku/proto`
- enable `store` protocol, but only as a client.
This implies that the nwaku node will not persist any historical messages itself,
but can query `store` service peers who do so.
To configure `store` as a service node,
see [this tutorial](./configure-store.md).

> **Note:** The commonly used `filter` and `lightpush` protocols are _not_ enabled by default.
Consult the [configuration guide](./configure.md) on how to configure your nwaku node to run these protocols.

Some typical non-default configurations are explained below.
For more advanced configuration, see the [configuration guide](./configure.md).

### Finding your listening address(es)

Find the log entry beginning with `Listening on`.
It should be printed at INFO level when you start your node,
and contains a list of all publically announced listening addresses for the nwaku node.

For example

```
INF 2022-05-11 16:42:30.591+02:00 Listening on                               topics="wakunode" tid=6661 file=wakunode2.nim:941 full=[/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H][/ip4/0.0.0.0/tcp/8000/ws/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H]
```

indicates that your node is listening on the TCP transport address

```
/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H
```

and websocket address

```
/ip4/0.0.0.0/tcp/8000/ws/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H
```

### Typical configuration (relay node)

The typical configuration for a nwaku node is to run the `relay` protocol,
subscribed to the default pubsub topic `/waku/2/default-waku/proto`,
and connecting to one or more existing peers.
We assume below that running nodes also participate in Discovery v5
to continually discover and connect to random peers for a more robust mesh.

#### Connecting to known peer(s)

A typical run configuration for a nwaku node is to connect to existing peers with known listening addresses using the `--staticnode` option.
The `--staticnode` option can be repeated for each peer you want to connect to on startup.
This is also useful if you want to run several nwaku instances locally
and therefore know the listening addresses of all peers.

As an example, consider a nwaku node that connects to two known peers
on the same local host (with IP `0.0.0.0`)
with TCP ports `60002` and `60003`,
and peer IDs `16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H` and `16Uiu2HAmFBA7LGtwY5WVVikdmXVo3cKLqkmvVtuDu63fe8safeQJ` respectively:

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --staticnode:/ip4/0.0.0.0/tcp/60002/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H \
  --staticnode:/ip4/0.0.0.0/tcp/60003/p2p/16Uiu2HAmFBA7LGtwY5WVVikdmXVo3cKLqkmvVtuDu63fe8safeQJ
```

> **Tip:** `--ports-shift` shifts all configured ports forward by the configured amount.
This is another useful option when running several nwaku instances on a single machine
and would like to avoid port clashes without manually configuring each port.

#### Connecting to the `wakuv2.prod` network

*See [this explainer](https://github.com/status-im/nwaku/blob/6ebe26ad0587d56a87a879d89b7328f67f048911/docs/contributors/waku-fleets.md) on the different networks and Waku v2 fleets.*

You can use DNS discovery to bootstrap connection to the existing production network.

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://ANTL4SLG2COUILKAPE7EF2BYNL2SHSHVCHLRD5J7ZJLN5R3PRJD2Y@prod.waku.nodes.status.im
```

#### Connecting to the `wakuv2.test` network

*See [this explainer](https://github.com/status-im/nwaku/blob/6ebe26ad0587d56a87a879d89b7328f67f048911/docs/contributors/waku-fleets.md) on the different networks and Waku v2 fleets.*

You can use DNS discovery to bootstrap connection to the existing test network.

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AOFTICU2XWDULNLZGRMQS4RIZPAZEHYMV4FYHAPW563HNRAOERP7C@test.waku.nodes.status.im
```

### Typical configuration (relay and store service node)

Often nwaku nodes choose to also store historical messages
from where it can be queried by other peers who may have been temporarily offline.
For example, a typical configuration for such a store service node,
[connecting to the `wakuv2.test`](#connecting-to-the-wakuv2test-fleet) fleet on startup,
appears below.

## Interact with a running nwaku node

A running nwaku node can be interacted with using the [Waku v2 JSON RPC API](https://rfc.vac.dev/spec/16/).

> **Note:** Private and Admin API functionality are disabled by default.
To configure a nwaku node with these enabled,
use the `--rpc-admin:true` and `--rpc-private:true` CLI options.