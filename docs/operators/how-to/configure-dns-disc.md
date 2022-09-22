# Use DNS discovery to connect to existing nodes

> **Note:** This page describes using DNS to discover other peers
and is unrelated to the [domain name configuration](./configure-domain.md) for your nwaku node.

A node can discover other nodes to connect to using [DNS-based discovery](../../tutorial/dns-disc.md).
The following command line options are available:

```
--dns-discovery              Enable DNS Discovery
--dns-discovery-url          URL for DNS node list in format 'enrtree://<key>@<fqdn>'
--dns-discovery-name-server  DNS name server IPs to query. Argument may be repeated.
```

- `--dns-discovery` is used to enable DNS discovery on the node.
Waku DNS discovery is disabled by default.
- `--dns-discovery-url` is mandatory if DNS discovery is enabled.
It contains the URL for the node list.
The URL must be in the format `enrtree://<key>@<fqdn>` where `<fqdn>` is the fully qualified domain name and `<key>` is the base32 encoding of the compressed 32-byte public key that signed the list at that location.
- `--dns-discovery-name-server` is optional and contains the IP(s) of the DNS name servers to query.
If left unspecified, the Cloudflare servers `1.1.1.1` and `1.0.0.1` will be used by default.

A node will attempt connection to all discovered nodes.

This can be used, for example, to connect to one of the existing fleets.
Current URLs for the published fleet lists:
- production fleet: `enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@prod.waku.nodes.status.im`
- test fleet: `enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@test.waku.nodes.status.im`

See the [separate tutorial](../../tutorial/dns-disc.md) for a complete guide to DNS discovery.