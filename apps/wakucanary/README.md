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
 -s, --shard         Shards index to subscribe to topics [ Argument may be repeated ]

```

The tool can be built as:

```console
$ make wakucanary
```

And used as follows. A reachable node that supports both `store` and `filter` protocols.

```console
$ ./build/wakucanary \
  --address=/dns4/store-01.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F \
  --protocol=store \
  --protocol=filter \
  --cluster-id=16 \
  --shard=64
$ echo $?
0
```

A node that can't be reached.
```console
$ ./build/wakucanary \
  --address=/dns4/store-01.do-ams3.status.staging.status.im/tcp/1000/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F \
  --protocol=store \
  --protocol=filter \
  --cluster-id=16 \
  --shard=64
$ echo $?
1
```

Note that a domain name can also be used.
```console
--- not defined yet 
$ echo $?
0
```

Websockets are also supported. The websocket port openned by waku canary is calculated as `$(--node-port) + 1000` (e.g. when you set `-np 60000`, the WS port will be `61000`)
```console
$ ./build/wakucanary --address=/ip4/127.0.0.1/tcp/7777/ws/p2p/16Uiu2HAm4ng2DaLPniRoZtMQbLdjYYWnXjrrJkGoXWCoBWAdn1tu --protocol=store --protocol=filter
$ ./build/wakucanary --address=/ip4/127.0.0.1/tcp/7777/wss/p2p/16Uiu2HAmB6JQpewXScGoQ2syqmimbe4GviLxRwfsR8dCpwaGBPSE --protocol=store --websocket-secure-key-path=MyKey.key --websocket-secure-cert-path=MyCertificate.crt
```
