# networkmonitor

Monitoring tool to run in an existing `waku` network with the following features:

* Keeps discovering new peers using `discv5`
* Tracks advertised capabilities of each node as per stored in the ENR `waku` field
* Attempts to connect to all nodes, tracking which protocols each node supports
* Presents grafana-ready metrics showing the state of the network in terms of locations, ips, number discovered peers, number of peers we could connect to, user-agent that each peer contains, content topics and the amount of rx messages in each one.
* Metrics are exposed through prometheus metrics but also with a custom rest api, presenting detailed information about each peer. These metrics are exposed via a rest api.

## Usage

```console
./build/networkmonitor --help
Usage:

networkmonitor [OPTIONS]...

The following options are available:

 -l, --log-level               Sets the log level [=LogLevel.DEBUG].
 -t, --timeout                 Timeout to consider that the connection failed [=chronos.seconds(10)].
 -b, --bootstrap-node          Bootstrap ENR node. Argument may be repeated. [=@[""]].
     --dns-discovery-url       URL for DNS node list in format 'enrtree://<key>@<fqdn>'.
 -r, --refresh-interval        How often new peers are discovered and connected to (in seconds) [=5].
     --metrics-server          Enable the metrics server: true|false [=true].
     --metrics-server-address  Listening address of the metrics server. [=ValidIpAddress.init("127.0.0.1")].
     --metrics-server-port     Listening HTTP port of the metrics server. [=8008].
     --metrics-rest-address    Listening address of the metrics rest server. [=127.0.0.1].
     --metrics-rest-port       Listening HTTP port of the metrics rest server. [=8009].
```

## Example

Connect to the network through a given bootstrap node, with default parameters. See metrics section for the data that it exposes.

```console
./build/networkmonitor --log-level=INFO --b="enr:-Nm4QOdTOKZJKTUUZ4O_W932CXIET-M9NamewDnL78P5u9DOGnZlK0JFZ4k0inkfe6iY-0JAaJVovZXc575VV3njeiABgmlkgnY0gmlwhAjS3ueKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuYWMtY24taG9uZ2tvbmctYy53YWt1djIucHJvZC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhAo0C-VvfgHiXrxZi3umDiooXMGY9FvYj5_d1Q4EeS7eyg3RjcIJ2X4N1ZHCCIyiFd2FrdTIP"
```

```console
./build/networkmonitor --log-level=INFO --dns-discovery-url=enrtree://AL65EKLJAUXKKPG43HVTML5EFFWEZ7L4LOKTLZCLJASG4DSESQZEC@prod.status.nodes.status.im
```

## Metrics

Metrics are divided into two categories:

* Prometheus metrics, exposed as i.e. gauges.
* Custom metrics, used for unconstrained labels such as peer information or content topics.
  - These metrics are not exposed through prometheus because since they are unconstrained, they can end up breaking the backend, as a new datapoint is generated for each one and it can reach up a point where is too much to handle.

### Prometheus Metrics

The following metrics are available. See `http://localhost:8008/metrics`

* `peer_type_as_per_enr`: Number of peers supporting each capability according to the ENR (Relay, Store, Lightpush, Filter)
* `peer_type_as_per_protocol`: Number of peers supporting each protocol, after a successful connection)
* `peer_user_agents`: List of useragents found in the network and their count

Other relevant metrics reused from `nim-eth`:

* `routing_table_nodes`: Inherited from nim-eth, number of nodes in the routing table
* `discovery_message_requests_outgoing_total`: Inherited from nim-eth, number of outgoing discovery requests, useful to know if the node is actively looking for new peers

### Custom Metrics

The following endpoints are available:

* `http://localhost:8009/allpeersinfo`: json list of all peers with extra information such as ip, location, supported protocols and last connection time.
* `http://localhost:8009/contenttopics`: content topic messages and its message count.
