## waku canary tool

Attempts to dial a peer and asserts it supports a given set of protocols.

```console
./build/wakucanary --help
Usage:

wakucanary [OPTIONS]...

The following options are available:

 -a, --address        Multiaddress of the peer node to attempt to dial.
 -t, --timeout        Timeout to consider that the connection failed [=chronos.seconds(10)].
 -p, --protocol       Protocol required to be supported: store,relay,lightpush,filter (can be used
                      multiple times).
 -l, --log-level      Sets the log level [=LogLevel.DEBUG].
 -np, --node-port      Listening port for waku node [=60000].
```

The tool can be built as:

```console
$ make wakucanary
```

And used as follows. A reachable node that supports both `store` and `filter` protocols.


```console
$ ./build/wakucanary --address=/ip4/8.210.222.231/tcp/30303/p2p/16Uiu2HAm4v86W3bmT1BiH6oSPzcsSr24iDQpSN5Qa992BCjjwgrD --protocol=store --protocol=filter
$ echo $?
0
```

A node that can't be reached.
```console
$ ./build/wakucanary --address=/ip4/8.210.222.231/tcp/1000/p2p/16Uiu2HAm4v86W3bmT1BiH6oSPzcsSr24iDQpSN5Qa992BCjjwgrD --protocol=store --protocol=filter
$ echo $?
1
```

Note that a domain name can also be used.
```console
$ ./build/wakucanary --address=/dns4/node-01.do-ams3.status.test.statusim.net/tcp/30303/p2p/16Uiu2HAkukebeXjTQ9QDBeNDWuGfbaSg79wkkhK4vPocLgR6QFDf --protocol=store --protocol=filter
$ echo $?
0
```

## networkmonitor

Monitoring tool to run in an existing `waku` network with the following features:
* Keeps discovering new peers using `discv5`
* Tracks advertised capabilities of each node as per stored in the ENR `waku` field
* Attempts to connect to all nodes, tracking which protocols each node supports
* Presents grafana-ready metrics showing the state of the network in terms of locations, ips, number discovered peers, number of peers we could connect to, user-agent that each peer contains, etc.
* Metrics are exposed through prometheus metrics but also with a custom rest api, presenting detailed information about each peer.

### Usage

```console
./build/networkmonitor --help
Usage:

networkmonitor [OPTIONS]...

The following options are available:

 -l, --log-level               Sets the log level [=LogLevel.DEBUG].
 -t, --timeout                 Timeout to consider that the connection failed [=chronos.seconds(10)].
 -b, --bootstrap-node          Bootstrap ENR node. Argument may be repeated. [=@[""]].
 -r, --refresh-interval        How often new peers are discovered and connected to (in minutes) [=10].
     --metrics-server          Enable the metrics server: true|false [=true].
     --metrics-server-address  Listening address of the metrics server. [=ValidIpAddress.init("127.0.0.1")].
     --metrics-server-port     Listening HTTP port of the metrics server. [=8008].
     --metrics-rest-address    Listening address of the metrics rest server. [=127.0.0.1].
     --metrics-rest-port       Listening HTTP port of the metrics rest server. [=8009].
```

### Example

Connect to the network through a given bootstrap node, with default parameters. Once its running, metrics will be live at `localhost:8008/metrics`

```console
./build/networkmonitor --log-level=INFO --b="enr:-Nm4QOdTOKZJKTUUZ4O_W932CXIET-M9NamewDnL78P5u9DOGnZlK0JFZ4k0inkfe6iY-0JAaJVovZXc575VV3njeiABgmlkgnY0gmlwhAjS3ueKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuYWMtY24taG9uZ2tvbmctYy53YWt1djIucHJvZC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhAo0C-VvfgHiXrxZi3umDiooXMGY9FvYj5_d1Q4EeS7eyg3RjcIJ2X4N1ZHCCIyiFd2FrdTIP"
```


### metrics

The following metrics are available. See `http://localhost:8008/metrics`

* peer_type_as_per_enr: Number of peers supporting each capability according the the ENR (Relay, Store, Lightpush, Filter)
* peer_type_as_per_protocol: Number of peers supporting each protocol, after a successful connection)
* peer_user_agents: List of useragents found in the network and their count

Other relevant metrics reused from `nim-eth`:
* routing_table_nodes: Inherited from nim-eth, number of nodes in the routing table
* discovery_message_requests_outgoing_total: Inherited from nim-eth, number of outging discovery requests, useful to know if the node is actiely looking for new peers

The following metrics are exposed via a custom rest api. See `http://localhost:8009/allpeersinfo`

* json list of all peers with extra information such as ip, locatio, supported protocols and last connection time.
