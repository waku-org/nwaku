# Waku v2 fleet: management & monitoring

## Background

Status currently maintains two fleets for `nim-waku` v2 nodes,
the `wakuv2.test` fleet and the `wakuv2.prod` (production) fleet.
They'll be referred to as `test` and `prod` in this document.
Status fleet nodes and addresses can be viewed [here](https://fleets.status.im/).

### Fleet overview

At the time of writing this, each fleet consists of three waku v2 nodes,
with a [websockify](https://github.com/novnc/websockify) WebSocket-to-TCP bridge for each node.
Waku v2 peers can choose to connect either directly to a node's TCP endpoint
or the bridged WebSocket depending on their own supported transports.
The `prod` fleet also has a deployed [`chat2bridge`](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md#bridge-messages-between-chat2-and-matterbridge),
which serves as a bridge between the [Waku v2 toy-chat](https://rfc.vac.dev/spec/22/) and Matterbridge.
The `chat2bridge` is currently deployed to the `node-01.do-ams3` datacentre
and configured to bridge toy-chat messages to the `#waku channel` on the Vac Discord Server.

### Fleet deployment rationale

The `test` fleet is automatically updated after every commit to the `nim-waku` `master` branch
and is therefore the most up to date representation of Waku v2 development.
It is suitable for testing new features before they're rolled out to the (more) stable `prod` fleet.

In general only the latest release of `nim-waku` is deployed to the `prod` fleet.
It requires manual updating and should therefore be more stable than `test`.
See the [section on Jenkins](#jenkins-for-deployment) below for more on the deployment process.

### Related repos

The [`infra-docs` repo](https://github.com/status-im/infra-docs) contains the most comprehensive overview of Status infrastructure.
This is a private repository. 
Feel free to contact someone in the team to request access.

The [`infra-nim-waku` repo](https://github.com/status-im/infra-nim-waku) contains the infrastructure definitions for Waku nodes implemented in Nim.

## Monitoring and management

The rest of this document highlights some infra services of specific interest to Waku v2 fleet monitoring and management:

1. [Consul](https://consul.infra.status.im/ui/do-ams3/services?filter=nim-waku) to view the health status of Waku nodes.
2. [Kibana](https://kibana.infra.status.im/app/discover#/) to view and filter logs.
3. [Grafana](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2) to view and filter metrics.
4. [Jenkins](https://ci.status.im/job/nim-waku/) to configure and deploy new builds to the fleets.

### 1. [Consul](https://consul.infra.status.im/ui/do-ams3/services?filter=nim-waku) for health checks

Consul provides a useful high-level view of the health of the  `nim-waku` fleets.
It aggregates the result of various monitoring checks
and shows the health status for the node itself, the RPC API, exposed WebSocket and metrics.
The datacentre can be changed in the upper left-hand corner.

### 2. [Kibana](https://kibana.infra.status.im/app/discover#/) for logs

Kibana is a powerful visualisation tool for Elasticsearch data.
For Waku v2 fleets it can be used to retrieve, filter and view the logs for all deployed services.
For example, to view the latest logs for `prod`,
Kibana can be opened in "Discover" mode with an [active filter for `fleet: wakuv2.prod`](https://kibana.infra.status.im/goto/87fde8e4bba7246ce3780a0c8344f4f0).

### 3. [Grafana](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1&refresh=5m) for metrics

The `Nim-Waku V2` Grafana dashboard displays live and historical metrics for Waku v2 nodes.
The default view includes metrics from both fleets,
though it's possible to filter by `Hostname`, `Fleet name` or `Data Center`.
The time range can also be configured -
by default the latest metrics will be shown.

The dashboard itself includes an _"At a glance"_ summary
with an overview of the latest connected peers, total messages, CPU usage, reported errors, etc.
The _"General"_ collection contains a more in-depth look at node, libp2p and performance-related metrics.
This is followed by separate panel collections showing _per-protocol_ metrics.

A copy of the `Nim-Waku V2` fleets dashboard is maintained in the [`nim-waku` repo](https://github.com/status-im/nim-waku/blob/master/metrics/waku_fleet_dashboard.json).
From time to time certain Prometheus queries may fail,
often when the underlying metrics are renamed.
Please report any broken panels via our Discord channels or by [creating an issue in `nim-waku`](https://github.com/status-im/nim-waku/issues/new).

### 4. [Jenkins](https://ci.status.im/job/nim-waku/) for deployment

The [`nim-waku` jobs](https://ci.status.im/job/nim-waku/) on Jenkins are configured to deploy `nim-waku` builds to the fleets.
1. [`deploy-wakuv2-test`](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-test/) is triggered automatically after every commit to the `nim-waku` `master` branch.
2. [`deploy-wakuv2-prod`](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-prod/) must be triggered manually. Usually this job is only built after a tagged release in `nim-waku`.

Each job can be manually triggered using the _"Build with Parameters"_ option.
Options under _"Configure"_ include the build triggers, build target and branches to build.
These should only be changed with care.

See [Continuous Integration docs](https://github.com/status-im/nim-waku/blob/master/docs/contributors/continuous-integration.md) for more.

## Quick links

 1. [`chat2bridge`](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md#bridge-messages-between-chat2-and-matterbridge)
 2.  [Consul for do-ams3](https://consul.infra.status.im/ui/do-ams3/services?filter=nim-waku)
 3. [Consul for ac-cn-hongkong-c](https://consul.infra.status.im/ui/ac-cn-hongkong-c/services?filter=nim-waku)
 4. [Consul for gc-us-central1-a](https://consul.infra.status.im/ui/gc-us-central1-a/services?filter=nim-waku)
 5. [Grafana Nim-Waku V2 dashboard](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1&refresh=5m)
 6. [`infra-docs` repo](https://github.com/status-im/infra-docs)
 7. [`infra-nim-waku` repo](https://github.com/status-im/infra-nim-waku)
 8. [Jenkins jobs for `nim-waku`](https://ci.status.im/job/nim-waku/)
 9. [Jenkins deploy-wakuv2-prod manual trigger](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-prod/build)
 10. [Jenkins deploy-wakuv2-test manual trigger](https://ci.status.im/job/nim-waku/job/deploy-wakuv2-test/build)
 11. [Kibana logs for `prod`](https://kibana.infra.status.im/goto/87fde8e4bba7246ce3780a0c8344f4f0)
 12. [Kibana logs for `test`](https://kibana.infra.status.im/goto/fc23759670fd08e9d32e81bb4e58733d)
 13. [Status fleets](https://fleets.status.im/)
 14. [Websockify](https://github.com/novnc/websockify)
