# Waku v2

This folder contains code related to Waku v2, both as a node and as a protocol.

## Introduction

This is an implementation in Nim of Waku v2, which is currently in draft/beta stage.

See [spec](https://specs.vac.dev/specs/waku/v2/waku-v2.html).

## How to Build & Run

### Prerequisites

* GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.

### Wakunode

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakunode2

# See available command line options
./build/wakunode2 --help

# Connect the client directly with the Status test fleet
# TODO NYI
#./build/wakunode2 --log-level:debug --discovery:off --fleet:test --log-metrics
```

Note: building `wakunode2` requires 2GB of RAM. The build will fail on systems not fulfilling this requirement.

Setting up a `wakunode2` on the smallest [digital ocean](https://docs.digitalocean.com/products/droplets/how-to/) droplet, you can either

* compile on a stronger droplet featuring the same CPU architecture and downgrade after compiling, or
* activate swap on the smallest droplet, or
* use Docker.


### Waku v2 Protocol Test Suite

```bash
# Run all the Waku v2 tests
make test2
```

You can also run a specific test (and alter compile options as you want):
```bash
# Get a shell with the right environment variables set
./env.sh bash
# Run a specific test
nim c -r ./tests/v2/test_waku_filter.nim
```

### Waku v2 Protocol Example

There is a more basic example, more limited in features and configuration than
the `wakunode1`, located in `examples/v2/basic2.nim`.

There is also a more full featured example in `examples/v2/chat2.nim`.

### Waku Quick Simulation

*NOTE: This section might be slightly out of date as it was written for Waku v1.*

One can set up several nodes, get them connected and then instruct them via the
JSON-RPC interface. This can be done via e.g. web3.js, nim-web3 (needs to be
updated) or simply curl your way out.

The JSON-RPC interface is currently the same as the one of Whisper. The only
difference is the addition of broadcasting the topics interest when a filter
with a certain set of topics is subcribed.

The quick simulation uses this approach, `start_network` launches a set of
`wakunode`s, and `quicksim` instructs the nodes through RPC calls.

Example of how to build and run:
```bash
# Build wakunode + quicksim with metrics enabled
make NIMFLAGS="-d:insecure" wakusim2

# Start the simulation nodes, this currently requires multitail to be installed
# TODO Partial support for Waku v2
./build/start_network2 --topology:FullMesh --amount:6 --test-node-peers:2
# In another shell run
./build/quicksim2
```

The `start_network2` tool will also provide a `prometheus.yml` with targets
set to all simulation nodes that are started. This way you can easily start
prometheus with this config, e.g.:

```bash
cd ./metrics/prometheus
prometheus --config.file=prometheus.yml
```

A Grafana dashboard containing the example dashboard for each simulation node
is also generated and can be imported in case you have Grafana running.
This dashboard can be found at `./metrics/waku-sim-all-nodes-grafana-dashboard.json`

To read more details about metrics, see [next](#using-metrics) section.

## Using Metrics

Metrics are available for valid envelopes and dropped envelopes.

To compile in an HTTP endpoint for accessing the metrics we need to provide the
`insecure` flag:
```bash
make NIMFLAGS="-d:insecure" wakunode2
./build/wakunode2 --metrics-server
```

Ensure your Prometheus config `prometheus.yml` contains the targets you care about, e.g.:

```
scrape_configs:
  - job_name: "waku"
    static_configs:
      - targets: ['localhost:8008', 'localhost:8009', 'localhost:8010']
```

For visualisation, similar steps can be used as is written down for Nimbus
[here](https://github.com/status-im/nimbus#metric-visualisation).

There is a similar example dashboard that includes visualisation of the
envelopes available at `metrics/waku-grafana-dashboard.json`.

## Spec support

*This section last updated November 16, 2020*

All Waku v2 specs, except for bridge, are currently in draft.

## Docker Image

By default, the target will be a docker image with `wakunode`, which is the Waku v1 node.
You can change this to `wakunode2`, the Waku v2 node like this:

```bash
make docker-image MAKE_TARGET=wakunode2
docker run --rm -it statusteam/nim-waku:latest --help
```

## Generating and configuring a private key

By default a node will generate a new, random key pair each time it boots,
resulting in a different public libp2p `multiaddrs` after each restart.

To maintain consistent addressing across restarts,
it is possible to configure the node with a previously generated private key using the `--nodekey` option.

```shell
wakunode2 --nodekey=<64_char_hex>
```

This option takes a [Secp256k1](https://en.bitcoin.it/wiki/Secp256k1) private key in 64 char hexstring format.

To generate such a key on Linux systems,
use the openssl `rand` command to generate a pseudo-random 32 byte hexstring.

```sh
openssl rand -hex 32
```

Example output:

```sh
$ openssl rand -hex 32
6a29e767c96a2a380bb66b9a6ffcd6eb54049e14d796a1d866307b8beb7aee58
```

where the key `6a29e767c96a2a380bb66b9a6ffcd6eb54049e14d796a1d866307b8beb7aee58` can be used as `nodekey`.

To create a reusable keyfile on Linux using `openssl`,
use the `ecparam` command coupled with some standard utilities
whenever you want to extract the 32 byte private key in hex format.

```sh
# Generate keyfile
openssl ecparam -genkey -name secp256k1 -out my_private_key.pem
# Extract 32 byte private key
openssl ec -in my_private_key.pem -outform DER | tail -c +8 | head -c 32| xxd -p -c 32
```

Example output:

```sh
read EC key
writing EC key
0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23
```

where the key `0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23` can be used as `nodekey`.

```sh
wakunode2 --nodekey=0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23
```

## Configuring a domain name

It is possible to configure an IPv4 DNS domain name that resolves to the node's public IPv4 address.

```shell
wakunode2 --dns4-domain-name=mynode.example.com
```

This allows for the node's publically announced `multiaddrs` to use the `/dns4` scheme.
In addition, nodes with domain name and [secure websocket configured](#enabling-websocket),
will generate a discoverable ENR containing the `/wss` multiaddr with `/dns4` domain name.
This is necessary to verify domain certificates when connecting to this node over secure websocket.

## Using DNS discovery to connect to existing nodes

A node can discover other nodes to connect to using [DNS-based discovery](../../docs/tutorial/dns-disc.md).
The following command line options are available:

```
--dns-discovery              Enable DNS Discovery
--dns-discovery-url          URL for DNS node list in format 'enrtree://<key>@<fqdn>'
--dns-discovery-name-server  DNS name server IPs to query. Argument may be repeated.
```

- `--dns-discovery` is used to enable DNS discovery on the node.
Waku DNS discovery is disabled by default.
- `--dns-discovery-url` is mandatory if DNS discovery is enabled.
It contains the URL for the node list.
The URL must be in the format `enrtree://<key>@<fqdn>` where `<fqdn>` is the fully qualified domain name and `<key>` is the base32 encoding of the compressed 32-byte public key that signed the list at that location.
- `--dns-discovery-name-server` is optional and contains the IP(s) of the DNS name servers to query.
If left unspecified, the Cloudflare servers `1.1.1.1` and `1.0.0.1` will be used by default.

A node will attempt connection to all discovered nodes.

This can be used, for example, to connect to one of the existing fleets.
Current URLs for the published fleet lists:
- production fleet: `enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@prod.waku.nodes.status.im`
- test fleet: `enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@test.waku.nodes.status.im`

See the [separate tutorial](../../docs/tutorial/dns-disc.md) for a complete guide to DNS discovery.

## Enabling Websocket

Websocket is currently the only Waku transport supported by browser nodes that uses [js-waku](https://github.com/status-im/js-waku).
Setting up websocket enables your node to directly serve browser peers.

A valid certificate is necessary to serve browser nodes,
you can use [`letsencrypt`](https://letsencrypt.org/):

```shell
sudo letsencrypt -d <your.domain.name>
```

You will need the `privkey.pem` and `fullchain.pem` files.

To enable secure websocket, pass the generated files to `wakunode2`:
Note, the default port for websocket is 8000.

```shell
wakunode2 --websocket-secure-support=true --websocket-secure-key-path="<letsencrypt cert dir>/privkey.pem" --websocket-secure-cert-path="<letsencrypt cert dir>/fullchain.pem"
```

### Self-signed certificates

Self-signed certificates are not recommended for production setups because:

- Browsers do not accept self-signed certificates
- Browsers do not display an error when rejecting a certificate for websocket.

However, they can be used for local testing purposes:

```shell
mkdir -p ./ssl_dir/
openssl req -x509 -newkey rsa:4096 -keyout ./ssl_dir/key.pem -out ./ssl_dir/cert.pem -sha256 -nodes
wakunode2 --websocket-secure-support=true --websocket-secure-key-path="./ssl_dir/key.pem" --websocket-secure-cert-path="./ssl_dir/cert.pem"
```



