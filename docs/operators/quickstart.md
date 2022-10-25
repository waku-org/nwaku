# Quickstart: running a nwaku node

This guide helps you run a nwaku node with typical configuration.
It connects your node to the `wakuv2.prod` fleet for bootstrapping
and enables discovery v5 for continuous peer discovery.
Only [`relay`](https://rfc.vac.dev/spec/11/) protocol is enabled.
For a more comprehensive overview,
see our [step-by-step guide](./overview.md).

## Option 1: run nwaku binary

*Prerequisites are the usual developer tools,
such as a C compiler, Make, Bash and Git.*

```bash
git clone --recurse-submodules https://github.com/status-im/nwaku
cd nwaku
make wakunode2
./build/wakunode2 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@prod.waku.nodes.status.im \
  --discv5-discovery \
  --nat=extip:[yourpublicip] # or, if you are behind a nat: --nat=any
```

## Option 2: run nwaku in a Docker container

*Prerequisite is a [Docker installation](./docker-quickstart.md#prerequisites).*

```bash
docker run -i -t -p 60000:60000 -p 9000:9000/udp \
  statusteam/nim-waku:v0.12.0 \ # or, the image:tag of your choice
    --dns-discovery:true \
    --dns-discovery-url:enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@prod.waku.nodes.status.im \
    --discv5-discovery \
    --nat:extip:[yourpublicip] # or, if you are behind a nat: --nat=any
```

## Tips and tricks

To find the public IP of your host,
you can use

```bash
dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | awk -F'"' '{ print $2}'
```
