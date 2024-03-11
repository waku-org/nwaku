# Waku fleet: management & monitoring

## Background

Status currently maintains two fleets for `nwaku` nodes,
the `waku.test` fleet and the `waku.sandbox` (sandbox) fleet.
They'll be referred to as `test` and `sandbox` in this document.
Status fleet nodes and addresses can be viewed [here](https://fleets.status.im/).

### Fleet overview

At the time of writing this, each fleet consists of three waku nodes,
with a [websockify](https://github.com/novnc/websockify) WebSocket-to-TCP bridge for each node.
Waku peers can choose to connect either directly to a node's TCP endpoint
or the bridged WebSocket depending on their own supported transports.
The `sandbox` fleet also has a deployed [`chat2bridge`](https://github.com/waku-org/nwaku/blob/master/docs/tutorial/chat2.md#bridge-messages-between-chat2-and-matterbridge),
which serves as a bridge between the [Waku toy-chat](https://rfc.vac.dev/spec/22/) and Matterbridge.
The `chat2bridge` is currently deployed to the `node-01.do-ams3` datacentre
and configured to bridge toy-chat messages to the `#waku channel` on the Vac Discord Server.

### Fleet deployment rationale

The `test` fleet is automatically updated after every commit to the `nwaku` repository `master` branch and is therefore the most up to date representation of Waku development.
It is suitable for testing new features before they're rolled out to the (more) stable `sandbox` fleet.

In general only the latest release of `nwaku` is deployed to the `sandbox` fleet.
It requires manual updating and should therefore be more stable than `test`.
See the [section on Jenkins](#jenkins-for-deployment) below for more on the deployment process.

### Related repos

The [`infra-docs` repo](https://github.com/status-im/infra-docs) contains the most comprehensive overview of Status infrastructure.
This is a private repository.
Feel free to contact someone in the team to request access.

The [`infra-nim-waku` repo](https://github.com/status-im/infra-nim-waku) contains the infrastructure definitions for Waku nodes implemented in Nim.

## Monitoring and management

The rest of this document highlights some infra services of specific interest to Waku fleet monitoring and management:

1. [Consul](https://consul.infra.status.im/ui/do-ams3/services?filter=nim-waku) to view the health status of Waku nodes.
2. [Kibana](https://kibana.infra.status.im/app/discover#/) to view and filter logs.
3. [Grafana](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2) to view and filter metrics.
4. [Jenkins](https://ci.infra.status.im/job/nim-waku/) to configure and deploy new builds to the fleets.

### 1. [Consul](https://consul.infra.status.im/ui/do-ams3/services?filter=nim-waku) for health checks

Consul provides a useful high-level view of the health of the  `nwaku` fleets.
It aggregates the result of various monitoring checks
and shows the health status for the node itself, the RPC API, exposed WebSocket and metrics.
The datacentre can be changed in the upper left-hand corner.

### 2. [Kibana](https://kibana.infra.status.im/app/discover#/) for logs

Kibana is a powerful visualisation tool for Elasticsearch data.
For Waku fleets it can be used to retrieve, filter and view the logs for all deployed services.
For example, to view the latest logs for `sandbox`,
Kibana can be opened in "Discover" mode with an [active filter for `fleet: waku.sandbox`](https://kibana.infra.status.im/goto/c0434f60-ca82-11ee-aaa4-85391103106b).

### 3. [Grafana](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1&refresh=5m) for metrics

The `Nim-Waku` Grafana dashboard displays live and historical metrics for Waku nodes.
The default view includes metrics from both fleets,
though it's possible to filter by `Hostname`, `Fleet name` or `Data Center`.
The time range can also be configured -
by default the latest metrics will be shown.

The dashboard itself includes an _"At a glance"_ summary
with an overview of the latest connected peers, total messages, CPU usage, reported errors, etc.
The _"General"_ collection contains a more in-depth look at node, libp2p and performance-related metrics.
This is followed by separate panel collections showing _per-protocol_ metrics.

A copy of the `Nim-Waku` fleets dashboard is maintained in the [`nwaku` repo](https://github.com/waku-org/nwaku/blob/master/metrics/waku-fleet-dashboard.json).
From time to time certain Prometheus queries may fail,
often when the underlying metrics are renamed.
Please report any broken panels via our Discord channels or by [creating an issue in `nwaku`](https://github.com/waku-org/nwaku/issues/new).

### 4. [Jenkins](https://ci.status.im/job/nim-waku/) for deployment

The [`nim-waku` jobs](https://ci.infra.status.im/job/nim-waku/) on Jenkins are configured to deploy `nwaku` builds to the fleets.
1. [`deploy-waku-test`](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-test/) is triggered automatically after every commit to the `nwaku` `master` branch.
2. [`deploy-waku-sandbox`](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/) must be triggered manually. Usually this job is only built after a tagged release in `nwaku`.

Each job can be manually triggered using the _"Build with Parameters"_ option.
Options under _"Configure"_ include the build triggers, build target and branches to build.
These should only be changed with care.

See [Continuous Integration docs](https://github.com/waku-org/nwaku/blob/master/docs/contributors/continuous-integration.md) for more.

## Quick links

 1. [`chat2bridge`](https://github.com/waku-org/nwaku/blob/master/docs/tutorial/chat2.md#bridge-messages-between-chat2-and-matterbridge)
 2.  [Consul for do-ams3](https://consul.infra.status.im/ui/do-ams3/services?filter=nim-waku)
 3. [Consul for ac-cn-hongkong-c](https://consul.infra.status.im/ui/ac-cn-hongkong-c/services?filter=nim-waku)
 4. [Consul for gc-us-central1-a](https://consul.infra.status.im/ui/gc-us-central1-a/services?filter=nim-waku)
 5. [Grafana Nim-Waku dashboard](https://grafana.infra.status.im/d/qrp_ZCTGz/nim-waku-v2?orgId=1&refresh=5m)
 6. [`infra-docs` repo](https://github.com/status-im/infra-docs)
 7. [`infra-waku` repo](https://github.com/status-im/infra-waku)
 8. [Jenkins jobs for `nim-waku`](https://ci.infra.status.im/job/nim-waku/)
 9. [Jenkins deploy-waku-sandbox manual trigger](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/build)
 10. [Jenkins deploy-waku-test manual trigger](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-test/build)
 11. [Kibana logs for `sandbox`](https://kibana.infra.status.im/goto/c0434f60-ca82-11ee-aaa4-85391103106b)
 12. [Kibana logs for `test`](https://kibana.infra.status.im/goto/7cd22f20-ca83-11ee-aaa4-85391103106b)
 13. [Status fleets](https://fleets.status.im/)
 14. [Status fleets - Table](https://fleets.waku.org)
 15. [Websockify](https://github.com/novnc/websockify)
