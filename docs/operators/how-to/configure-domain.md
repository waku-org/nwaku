# Configure a domain name

It is possible to configure an IPv4 DNS domain name that resolves to the node's public IPv4 address.

```shell
wakunode2 --dns4-domain-name=mynode.example.com
```

This allows for the node's publically announced `multiaddrs` to use the `/dns4` scheme.
In addition, nodes with domain name and [secure websocket configured](./configure-websocket.md),
will generate a discoverable ENR containing the `/wss` multiaddr with `/dns4` domain name.
This is necessary to verify domain certificates when connecting to this node over secure websocket.