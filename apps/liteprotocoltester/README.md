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

Lite Protocol Tester application is built under name `liteprotocoltester` in apps/liteprotocoltester folder.

Starting from nwaku repository root:
```bash
make liteprotocoltester
cd apps/liteprotocoltester
docker compose build
docker compose up -d
docker compose logs -f receivernode
```

## Configure

### Environment variables for docker compose runs

|   Variable     | Description | Default |
| ---: | :--- | :--- |
| NUM_MESSAGES   | Number of message to publish | 120 |
| DELAY_MESSAGES | Frequency of messages in milliseconds | 1000 |
| PUBSUB | Used pubsub_topic for testing | /waku/2/default-waku/proto |
| CONTENT_TOPIC  | content_topic for testing | /tester/1/light-pubsub-example/proto |

### Lite Protocol Tester application cli options

|  Option     | Description | Default |
| :--- | :--- | :--- |
| --test_func | separation of PUBLISHER or RECEIVER mode | RECEIVER |
| --service-node| Address of the service node to use for lightpush and/or filter service | - |
| --num-messages | Number of message to publish | 120 |
| --delay-messages | Frequency of messages in milliseconds | 1000 |
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

