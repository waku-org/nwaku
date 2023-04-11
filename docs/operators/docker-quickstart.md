# Quickstart: running nwaku in a Docker container

This guide explains how to run a nwaku node in a Docker container.

## Prerequisites

Make sure you have Docker installed.
Installation instructions for different platforms can be found in the [Docker docs](https://docs.docker.com/engine/install/).

For example, to use Docker's convenience script for installation:

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

## Step 1: Get Docker image

Nwaku Docker images are published to the Docker Hub public registry under [`statusteam/nim-waku`](https://hub.docker.com/r/statusteam/nim-waku).
For specific releases the published images are tagged with the release version, e.g. [`statusteam/nim-waku:v0.16.0`](https://hub.docker.com/layers/statusteam/nim-waku/v0.16.0/images/sha256-7b7f14e7aa1c0a70db297dfd4d43251bda339a14da32885f57ee4b25983c9470?context=explore).
Images are also published for each commit to the `master` branch in the [nwaku repo](https://github.com/status-im/nwaku/commits/master)
and tagged with the corresponding commit hash.
See [`statusteam/nim-waku`](https://hub.docker.com/r/statusteam/nim-waku/tags) on Docker Hub for a full list of available tags.

To pull the image of your choice, use

```bash
docker pull statusteam/nim-waku:v0.16.0 # or, whichever tag you prefer in the format statusteam/nim-waku:[tag]
```

You can also build the Docker image locally using

```bash
git clone --recurse-submodules https://github.com/status-im/nwaku
cd nwaku
docker build -t statusteam/nim-waku:latest .
```

## Step 2: Run

To run nwaku in a new Docker container,
use the following command:

```bash
docker run [OPTIONS] IMAGE [ARG...]
```

where `OPTIONS` are your selected Docker options,
`IMAGE` the image and tag you pulled from the registry or built in Step 1
and `ARG...` the list of nwaku arguments for your [chosen nwaku configuration](./how-to/configure.md).

For Docker options we recommend explicit port mappings (`-p`) at least
for your exposed libp2p listening ports
and any discovery ports (e.g. the Waku discv5 port) that must be reachable from outside the host.

As an example, consider the following command to run nwaku in a Docker container with the most typical configuration:

```bash
docker run -i -t -p 60000:60000 -p 9000:9000/udp statusteam/nim-waku:v0.16.0 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@prod.waku.nodes.status.im \
  --discv5-discovery \
  --nat:extip:[yourpublicip] # or, if you are behind a nat: --nat=any
```

This runs nwaku in a new container from the `statusteam/nim-waku:v0.16.0` image,
connects to `wakuv2.prod` as bootstrap fleet and
enables [Waku Discovery v5](https://rfc.vac.dev/spec/33/) for ambient peer discovery,
while mapping the default libp2p listening port (`60000`)
and default discv5 UDP port (`9000`) to the host.

> **Tip:** The `docker run` command will pull the specified image from Docker Hub if it's not yet available locally,
so it's possible to skip Step 1 and pull the image from your configured registry automatically when running.

If you've used the `-i` and `-t` Docker options when running the new container,
the `run` command would have allocated an interactive terminal
where you'll see the `stdout` logs from the running nwaku process.
To detach gracefully from the running container,
use `Ctrl-P` followed by `Ctrl-Q`.
