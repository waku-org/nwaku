# nim-waku
## Introduction
The nim-waku repository holds a Nim implementation of the [Waku protocol](https://specs.vac.dev/waku/waku.html) and a cli application `wakunode` that allows you to run a Waku
enabled node from command line.

The Waku specification is still in draft and thus this implementation will
change accordingly. For supported specification details see [here](#spec-support).

Additionally the original Whisper (EIP-627) protocol can also be enabled as can
an experimental Whisper - Waku bridging option.

The underlying transport protocol is [rlpx + devp2p](https://github.com/ethereum/devp2p/blob/master/rlpx.md) and the [nim-eth](https://github.com/status-im/nim-eth) implementation is used.

This repository is also a place for experimenting with possible future versions
of Waku such as replacing the transport protocol with libp2p.

## How to Build & Run

### Prerequisites

* GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.
* PCRE

More information on the installation of these can be found [here](https://github.com/status-im/nimbus#prerequisites).

### Wakunode

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakunode

# See available command line options
./build/wakunode --help

# Connect the client directly with the Status test fleet
./build/wakunode --log-level:debug --discovery:off --fleet:test --log-metrics
```

You can also create a Docker image using:
```bash
make docker-image
docker run --rm -it statusteam/nim-waku:latest --help
```

### Waku Protocol Test Suite

```bash
# Run all the tests
make test
```

You can also run a specific test (and alter compile options as you want):
```bash
# Get a shell with the right environment variables set
./env.sh bash
# Run a specific test
nim c -r ./tests/v1/test_waku_connect.nim
```

### Waku Protocol Example
There is a more basic example, more limited in features and configuration than
the `wakunode`, located in `examples/v1/example.nim`.

More information on how to run this example can be found it its
[readme](examples/v1/README.md).

### Waku Quick Simulation
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
make NIMFLAGS="-d:insecure" wakusim

# Start the simulation nodes, this currently requires multitail to be installed
./build/start_network --topology:FullMesh --amount:6 --test-node-peers:2
# In another shell run
./build/quicksim
```

The `start_network` tool will also provide a `prometheus.yml` with targets
set to all simulation nodes that are started. This way you can easily start
prometheus with this config, e.g.:

```bash
cd ./metrics/prometheus
prometheus
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
make NIMFLAGS="-d:insecure" wakunode
./build/wakunode --metrics-server
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
envelopes available at `waku/node/v1/examples/waku-grafana-dashboard.json`.

## Spec support

*This section last updated April 21, 2020*

This client of Waku is spec compliant with [Waku spec v1.0](https://specs.vac.dev/waku/waku.html).

It doesn't yet implement the following recommended features:
- No support for rate limiting
- No support for DNS discovery to find Waku nodes
- It doesn't disconnect a peer if it receives a message before a Status message
- No support for negotiation with peer supporting multiple versions via Devp2p capabilities in `Hello` packet

Additionally it makes the following choices:
- It doesn't send message confirmations
- It has partial support for accounting:
  - Accounting of total resource usage and total circulated envelopes is done through metrics But no accounting is done for individual peers.

## Waku v2

Waku v2 is under active development but is currently in an early alpha state.
See `waku/node` and `waku/protocol` directory for more details on the current
state.

Here's a post outlining the [current plan for Waku
v2](https://vac.dev/waku-v2-plan), and here's the current roadmap and progress
https://github.com/vacp2p/research/issues/40
