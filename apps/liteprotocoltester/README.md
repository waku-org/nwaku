# Waku - Lite Protocol Tester

## Aim

Testing reliability of light client protocols in different scale.
Measure message delivery reliability and latency between light push client(s) and a filter client(s) node(s).

## Concept of testing

A tester node is configured either 'publisher' or 'receiver' and connects to a certain service node.
All service protocols are disabled except for lightpush client or filter client. This way we would like to simulate
a light client application.
Each publisher pumps messages to the network in a preconfigured way (number of messages, frequency) while on the receiver side
we would like to track and measure message losses, mis-ordered receives, late arrived messages and latencies.
Ideally the tester nodes will connect to different edge of the network where we can gather more result from mulitple publishers
and multiple receivers.

Publishers are fill all message payloads with information about the test message and sender, helping the receiver side to calculate results.

## Usage

### Using lpt-runner

For ease of use, you can clone lpt-runner repository. That will utilize previously pushed liteprotocoltester docker image.
It is recommended to use this method for fleet testing.

```bash
git clone https://github.com/waku-org/lpt-runner.git
cd lpt-runner

# check Reame.md for more information
# edit .env file to your needs

docker compose up -d

# navigate localhost:3033 to see the lite-protocol-tester dashboard
```

> See more detailed examples below.

### Integration with waku-simulator!

- For convenience, integration is done in cooperation with waku-simulator repository, but nothing is tightly coupled.
- waku-simulator must be started separately with its own configuration.
- To enable waku-simulator working without RLN currently a separate branch is to be used.
- When waku-simulator is configured and up and running, lite-protocol-tester composite docker setup can be started.

```bash

# Start waku-simulator

git clone https://github.com/waku-org/waku-simulator.git ../waku-simulator
cd ../waku-simulator
git checkout chore-integrate-liteprotocoltester

# optionally edit .env file

docker compose -f docker-compose-norln.yml up -d

# navigate localhost:30001 to see the waku-simulator dashboard

cd ../{your-repository}

make  LOG_LEVEL=DEBUG liteprotocoltester

cd apps/liteprotocoltester

# optionally edit .env file

docker compose -f docker-compose-on-simularor.yml build
docker compose -f docker-compose-on-simularor.yml up -d
docker compose -f docker-compose-on-simularor.yml logs -f receivernode
```
#### Current setup

- waku-simulator is configured to run with 25 full node
- liteprotocoltester is configured to run with 3 publisher and 1 receiver
- liteprotocoltester is configured to run 1 lightpush service and a filter service node
  - light clients are connected accordingly
- publishers will send 250 messages in every 200ms with size between 1KiB and 120KiB
- Notice there is a configurable wait before start publishing messages as it is noticed time is needed for the service nodes to get connected to full nodes from simulator
- light clients will print report on their and the connected service node's connectivity to the network in every 20 secs.

#### Test monitoring

Navigate to http://localhost:3033 to see the lite-protocol-tester dashboard.

### Run independently on a chosen waku fleet

This option is simple as is just to run the built liteprotocoltester binary with run_tester_node.sh script.

Syntax:
`./run_tester_node.sh <path-to-liteprotocoltester-binary> <SENDER|RECEIVER> <service-node-address>`

How to run from you nwaku repository:
```bash
cd ../{your-repository}

make  LOG_LEVEL=DEBUG liteprotocoltester

cd apps/liteprotocoltester

# optionally edit .env file

# run publisher side
./run_tester_node.sh ../../build/liteprotocoltester SENDER [chosen service node address that support lightpush]

# or run receiver side
./run_tester_node.sh ../../build/liteprotocoltester RECEIVER [chosen service node address that support filter service]
```

#### Recommendations

In order to run on any kind of network, it is recommended to deploy the built `liteprotocoltester` binary with the `.env` file and the `run_tester_node.sh` script to the desired machine.

Select a lightpush service node and a filter service node from the targeted network, or you can run your own. Note down the selected peers peer_id.

Run a SENDER role liteprotocoltester and a RECEIVER role one on different terminals. Depending on the test aim, you may want to redirect the output to a file.

> RECEIVER side will periodically print statistics to standard output.

## Configuration

### Environment variables for docker compose runs

|   Variable     | Description | Default |
| ---: | :--- | :--- |
| NUM_MESSAGES   | Number of message to publish, 0 means infinite | 120 |
| DELAY_MESSAGES | Frequency of messages in milliseconds | 1000 |
| PUBSUB | Used pubsub_topic for testing | /waku/2/rs/66/0 |
| CONTENT_TOPIC  | content_topic for testing | /tester/1/light-pubsub-example/proto |
| CLUSTER_ID  | cluster_id of the network | 16 |
| START_PUBLISHING_AFTER | Delay in seconds before starting to publish to let service node connected | 5 |
| MIN_MESSAGE_SIZE | Minimum message size in bytes | 1KiB |
| MAX_MESSAGE_SIZE | Maximum message size in bytes | 120KiB |


### Lite Protocol Tester application cli options

|  Option     | Description | Default |
| :--- | :--- | :--- |
| --test_func | separation of PUBLISHER or RECEIVER mode | RECEIVER |
| --service-node| Address of the service node to use for lightpush and/or filter service | - |
| --bootstrap-node| Address of the fleet's bootstrap node to use to determine service peer randomly choosen from the network. `--service-node` switch has precedence over this | - |
| --num-messages | Number of message to publish | 120 |
| --delay-messages | Frequency of messages in milliseconds | 1000 |
| --min-message-size | Minimum message size in bytes | 1KiB |
| --max-message-size | Maximum message size in bytes | 120KiB |
| --start-publishing-after | Delay in seconds before starting to publish to let service node connected in seconds | 5 |
| --pubsub-topic | Used pubsub_topic for testing | /waku/2/default-waku/proto |
| --content_topic | content_topic for testing | /tester/1/light-pubsub-example/proto |
| --cluster-id | Cluster id for the test | 0 |
| --config-file | TOML configuration file to fine tune the light waku node<br>Note that some configurations (full node services) are not taken into account | - |
| --nat |Same as wakunode "nat" configuration, appear here to ease test setup | any |
| --rest-address | For convenience rest configuration can be done here | 127.0.0.1 |
| --rest-port | For convenience rest configuration can be done here | 8654 |
| --rest-allow-origin | For convenience rest configuration can be done here | * |
| --log-level | Log level for the application | DEBUG |
| --log-format | Logging output format (TEXT or JSON) | TEXT |
| --metrics-port | Metrics scarpe port | 8003 |

### Specifying peer addresses

Service node or bootstrap addresses can be specified in multiadress or ENR form.

### Using bootstrap nodes

There are multiple benefits of using bootstrap nodes. By using them liteprotocoltester will use Peer Exchange protocol to get possible peers from the network that are capable to serve as service peers for testing. Additionally it will test dial them to verify their connectivity - this will be reported in the logs and on dashboard metrics.
Also by using bootstrap node and peer exchange discovery, litprotocoltester will be able to simulate service peer switch in case of failures. There are built in tresholds count for service peer failures (3) after service peer will be switched during the test. Also there will be max 10 trials of switching peer before test declared failed and quit.
These service peer failures are reported, thus extending network reliability measures.

### Docker image notice

#### Building for docker compose runs on simulator or standalone
Please note that currently to ease testing and development tester application docker image is based on ubuntu and uses the externally pre-built binary of 'liteprotocoltester'.
This speeds up image creation. Another dokcer build file is provided for proper build of boundle image.

> `Dockerfile.liteprotocoltester` will create an ubuntu based image with the binary copied from the build directory.

> `Dockerfile.liteprotocoltester.compile` will create an ubuntu based image completely compiled from source. This can be slow.

#### Creating standalone runner docker image

To ease the work with lite-protocol-tester, a docker image is possible to build.
With that image it is easy to run the application in a container.

> `Dockerfile.liteprotocoltester` will create an ubuntu image with the binary copied from the build directory. You need to pre-build the application.

Here is how to build and run:
```bash
cd <your-repository>
make liteprotocoltester

cd apps/liteprotocoltester
docker build -t liteprotocoltester:latest -f Dockerfile.liteprotocoltester ../..

# alternatively you can push it to a registry

# edit and adjust .env file to your needs and for the network configuration

docker run --env-file .env liteprotocoltester:latest RECEIVER <service-node-peer-address>

docker run --env-file .env liteprotocoltester:latest SENDER <service-node-peer-address>
```

#### Run test with auto service peer selection from a fleet using bootstrap node

```bash

docker run --env-file .env liteprotocoltester:latest RECEIVER <bootstrap-node-peer-address> BOOTSTRAP

docker run --env-file .env liteprotocoltester:latest SENDER <bootstrap-node-peer-address> BOOTSTRAP
```

> Notice that official image is also available at harbor.status.im/wakuorg/liteprotocoltester:latest

## Examples

### Bootstrap or Service node selection

The easiest way to get the proper bootstrap nodes for the tests from https://fleets.status.im page.
Adjust on which fleets you would like to run the tests.

> Please note that not all of them configured to support Peer Exchange protocol, those ones cannot be for bootstrap nodes for `liteprotocoltester`.

### Environment variables
You need not necessary to use .env file, although it can be more convenient.
Anytime you can override all or part of the environment variables defined in the .env file.

### Run standalone

Example of running the liteprotocoltester in standalone mode on status.stagin network.
Testing includes using bootstrap nodes to gather service peers from the network via Peer Exchange protocol.
Both parties will test-dial all the peers retrieved with the corresponding protocol.
Sender will start publishing messages after 60 seconds, sending 200 messages with 1 second delay between them.
Message size will be between 15KiB and 145KiB.
Cluster id and Pubsub-topic must be accurately set according to the network configuration.

The example shows that either multiaddress or ENR form accepted.

```bash
export START_PUBLISHING_AFTER=60
export NUM_MESSAGES=200
export DELAY_MESSAGES=1000
export MIN_MESSAGE_SIZE=15Kb
export MAX_MESSAGE_SIZE=145Kb
export PUBSUB=/waku/2/rs/16/32
export CONTENT_TOPIC=/tester/2/light-pubsub-test/fleet
export CLUSTER_ID=16

docker run harbor.status.im/wakuorg/liteprotocoltester:latest RECEIVER /dns4/boot-01.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAmQE7FXQc6iZHdBzYfw3qCSDa9dLc1wsBJKoP4aZvztq2d BOOTSTRAP

# in different terminal session, repeat the exports and run the other party of the test.
docker run harbor.status.im/wakuorg/liteprotocoltester:latest SENDER enr:-QEiuECJPv2vL00Jp5sTEMAFyW7qXkK2cFgphlU_G8-FJuJqoW_D5aWIy3ylGdv2K8DkiG7PWgng4Ql_VI7Qc2RhBdwfAYJpZIJ2NIJpcIQvTKi6im11bHRpYWRkcnO4cgA2NjFib290LTAxLmFjLWNuLWhvbmdrb25nLWMuc3RhdHVzLnN0YWdpbmcuc3RhdHVzLmltBnZfADg2MWJvb3QtMDEuYWMtY24taG9uZ2tvbmctYy5zdGF0dXMuc3RhZ2luZy5zdGF0dXMuaW0GAbveA4Jyc40AEAUAAQAgAEAAgAEAiXNlY3AyNTZrMaEDkbgV7oqPNmFtX5FzSPi9WH8kkmrPB1R3n9xRXge91M-DdGNwgnZfg3VkcIIjKIV3YWt1Mg0 BOOTSTRAP

```

### Use of lpt-runner

Another method is to use [lpt-runner repository](https://github.com/waku-org/lpt-runner/tree/master).
This extends testing with grafana dashboard and ease the test setup.
Please read the corresponding [README](https://github.com/waku-org/lpt-runner/blob/master/README.md) there as well.

In this example we will run similar test as above but there will be 3 instances of publisher nodes and 1 receiver node.
This test uses waku.sandbox fleet which is connected to TWN. This implies lower message rates due to the RLN rate limation.
Also leave a gap of 120 seconds before starting to publish messages to let receiver side fully finish peer test-dialing.
For TWN network it is always wise to use bootstrap nodes with Peer Exchange support.

> Theoritically we can use the same bootstrap nodes for both parties, but it is recommended to use different ones to simulate different network edges, thus getting more meaningful results.

```bash
git clone https://github.com/waku-org/lpt-runner.git
cd lpt-runner

export NUM_PUBLISHER_NODES=3
export NUM_RECEIVER_NODES=1
export START_PUBLISHING_AFTER=120
export NUM_MESSAGES=300
export DELAY_MESSAGES=7000
export MIN_MESSAGE_SIZE=15Kb
export MAX_MESSAGE_SIZE=145Kb
export PUBSUB=/waku/2/rs/1/4
export CONTENT_TOPIC=/tester/2/light-pubsub-test/twn
export CLUSTER_ID=1

export FILTER_BOOTSTRAP=/dns4/node-01.ac-cn-hongkong-c.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmQYiojgZ8APsh9wqbWNyCstVhnp9gbeNrxSEQnLJchC92
export LIGHTPUSH_BOOTSTRAP=/dns4/node-01.do-ams3.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmNaeL4p3WEYzC9mgXBmBWSgWjPHRvatZTXnp8Jgv3iKsb

docker compose up -d

# we can check logs from one or all SENDER
docker compose logs -f --index 1 publishernode

# for checking receiver side performance
docker compose logs -f receivernode

# when test completed
docker compose down
```

For dashboard navigate to http://localhost:3033
