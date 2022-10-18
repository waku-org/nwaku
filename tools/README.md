## waku canary tool

Attempts to dial a peer and asserts it supports a given set of protocols.

```console
Usage:

wakucanary [OPTIONS]...

The following options are available:

 -a, --address        Multiaddress of the peer node to attempt to dial.
 -t, --timeout        Timeout to consider that the connection failed [=chronos.seconds(10)].
 -p, --protocol       Protocol required to be supported: store,relay,lightpush,filter (can be used
                      multiple times).
 -l, --log-level      Sets the log level [=LogLevel.DEBUG].
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