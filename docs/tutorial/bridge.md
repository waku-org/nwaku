# Bridging messages between Waku v1 and Waku v2

## Background

The `wakubridge` application allows bridging messages between Waku v1 and Waku v2 networks.
Packets received on the Waku v1 network are published once on the Waku v2 network using [`17/WAKU2-RELAY`](https://rfc.vac.dev/spec/17/).
Similarly, Waku v2 messages received on the configured [`17/WAKU2-RELAY`](https://rfc.vac.dev/spec/17/) pubsub topic are bridged to the Waku v1 network.
[`15/WAKU2-BRIDGE`](https://rfc.vac.dev/spec/15/) specifies how Waku v2 messages are converted to Waku v1 envelopes and vice versa.
The `wakubridge` application follows the topic recommmendations for bridging as set out in [`23/WAKU2-TOPICS`](https://rfc.vac.dev/spec/23/#bridging-waku-v1-and-waku-v2)

## Setting up a `wakubridge`

Start by compiling the `wakubridge` binary.

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakubridge

# See available command line options
./build/wakubridge --help
```

The next step is to run a `wakubridge` connected to both a Waku v1 and a Waku v2 network.

### Connecting to a Waku v1 network

Many [config options available for Waku v1 nodes](../../waku/v1/README.md) are also available for the `wakubridge`, with a slight change in the naming (most often a `-v1`-suffix).
This includes configuration to connect to a peer or a fleet of peers.
For example, to connect the bridge to the existing Status Waku v1 `test` fleet:

```bash
./build/wakubridge --fleet-v1:test
```

To connect the bridge directly to a static enode URL:

```bash
./build/wakubridge --staticnode-v1:<enode-url>
```

The `--staticnode-v1` argument may be repeated.

### Connecting to a Waku v2 network

Similarly, several [config options available for Waku v2 nodes](../../waku/v2/README.md) are also available for the `wakubridge`, with a slight change in the naming (most often a `-v2`-suffix).
This includes configuration to connect to static Waku v2 peers:

```bash
./build/wakubridge --staticnode-v2:<peer-multiaddr>
```

The `--staticnode-v2` argument may be repeated.

### Setting the Waku v1 and Waku v2 private keys

It is possible to set the v1 and v2 node private keys for the bridge:

```bash
./build/wakubridge --nodekey-v1:<v1-private-key-as-hex> --nodekey-v2:<v2-private-key-as-hex>
```

### Configuration summary

A typical `wakubridge` setup, combining the configuration items above, could look something like this:

```bash
./build/wakubridge --nodekey-v1:<v1-private-key-as-hex> --nodekey-v2:<v2-private-key-as-hex> --staticnode-v1:<enode-url> --staticnode-v2:<peer-multiaddr>
```

By default the `wakubridge` will then begin to bridge all Waku v1 messages routed by `staticnode-v1` to the Waku v2 network defined by the default Waku v2 pubsub topic (`/waku/2/default-waku/proto`) and participated in by `staticnode-v2`.
Waku v2 messages on the default Waku v2 pubsub topic will similarly be bridged to Waku v1.
This is the likely configuration for most `wakubridge` setups.

### Other configuration

For testing purposes, or for advanced bridging applications,
it is possible to run the `wakubridge` application with a Waku v1 topic interest:

```bash
./build/wakubridge --waku-v1-topic-interest:true
```

It is also possible to change the default Waku v2 pubsub topic from/to which messages are bridged:

```bash
./build/wakubridge --bridge-pubsub-topic:/waku/2/my-bridge-pubsub-topic/proto
```
