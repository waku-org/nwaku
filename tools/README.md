## waku canary tool

Attempts to dial a peer and asserts it supports a given set of protocols.

```console
The following options are available:

 --address       Multiaddress of the peer node to attemp to dial.
 --timeout       Timeout to consider that the connection failed [=chronos.seconds(10)].
 --protocol      Protocol required to be supported: store,static,lightpush,filter (can be used
                 multiple times).
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