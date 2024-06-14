# waku canary tool

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
 -np, --node-port     Listening port for waku node [=60000].
     --websocket-secure-key-path  Secure websocket key path:   '/path/to/key.txt' .
     --websocket-secure-cert-path  Secure websocket Certificate path:   '/path/to/cert.txt' .
 -c, --cluster-id     Cluster ID of the fleet node to check status [Default=1]
 -s, --shards         Shards index to subscribe to topics [ Argument may be repeated ]

```

The tool can be built as:

```console
$ make wakucanary
```

And used as follows. A reachable node that supports both `store` and `filter` protocols.

```console
$ ./build/wakucanary --address=/dns4/node-01.ac-cn-hongkong-c.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmSJvSJphxRdbnigUV5bjRRZFBhTtWFTSyiKaQByCjwmpV --protocol=store --protocol=filter
$ echo $?
0
```

A node that can't be reached.
```console
$ ./build/wakucanary --address=/dns4/node-01.ac-cn-hongkong-c.waku.sandbox.status.im/tcp/1000/p2p/16Uiu2HAmSJvSJphxRdbnigUV5bjRRZFBhTtWFTSyiKaQByCjwmpV --protocol=store --protocol=filter
$ echo $?
1
```

Note that a domain name can also be used.
```console
$ ./build/wakucanary --address=/dns4/node-01.do-ams3.status.test.statusim.net/tcp/30303/p2p/16Uiu2HAkukebeXjTQ9QDBeNDWuGfbaSg79wkkhK4vPocLgR6QFDf --protocol=store --protocol=filter
$ echo $?
0
```

Websockets are also supported. The websocket port openned by waku canary is calculated as `$(--node-port) + 1000` (e.g. when you set `-np 60000`, the WS port will be `61000`)
```console
$ ./build/wakucanary --address=/ip4/127.0.0.1/tcp/7777/ws/p2p/16Uiu2HAm4ng2DaLPniRoZtMQbLdjYYWnXjrrJkGoXWCoBWAdn1tu --protocol=store --protocol=filter
$ ./build/wakucanary --address=/ip4/127.0.0.1/tcp/7777/wss/p2p/16Uiu2HAmB6JQpewXScGoQ2syqmimbe4GviLxRwfsR8dCpwaGBPSE --protocol=store --websocket-secure-key-path=MyKey.key --websocket-secure-cert-path=MyCertificate.crt
```
