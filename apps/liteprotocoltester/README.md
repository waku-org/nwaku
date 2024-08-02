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

## Phases of development

### Phase 1

At the first phase we aims to demonstrate the concept of the testing all boundled into a docker-compose environment where we run
one service (full)node and a publisher and a receiver node.
At this stage we can only configure number of messages and fixed frequency of the message pump. We do not expect message losses and any significant latency hence the test setup is very simple.

### Further plans

- Add more configurability (randomized message sizes, usage of more content topics and support for static sharding).
- Extend collected metrics and polish reporting.
  - Add test metrics to graphana dashboard.
- Support for static sharding and auto sharding for being able to test under different conditions.
- ...

## Usage

### Phase 1

> NOTICE: This part is obsolate due integration with waku-simulator.
> It needs some rework to make it work again standalone.

Lite Protocol Tester application is built under name `liteprotocoltester` in apps/liteprotocoltester folder.

Starting from nwaku repository root:
```bash
make liteprotocoltester
cd apps/liteprotocoltester
docker compose build
docker compose up -d
docker compose logs -f receivernode
```

### Phase 2

> Integration with waku-simulator!

- For convenient integration is done in cooperation with waku-simulator repository, but nothing is tightly coupled.
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

### Phase 3

> Run independently on a chosen waku fleet

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

## Configure

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



### Docker image notice

Please note that currently to ease testing and development tester application docker image is based on ubuntu and uses the externally pre-built binary of 'liteprotocoltester'.
This speeds up image creation. Another dokcer build file is provided for proper build of boundle image.

