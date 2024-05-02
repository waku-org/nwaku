when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ../../waku/common/logging, ../../waku/factory/[waku, networks_config, external_config]
import
  std/[options, strutils, os, sequtils],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto

export
  networks_config, waku, logging, options, strutils, os, sequtils, stewNet, chronicles,
  chronos, metrics, libbacktrace, crypto

proc setup*(): Waku =
  const versionString = "version / git commit hash: " & waku.git_version
  let rng = crypto.newRng()

  let confRes = WakuNodeConf.load(version = versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error = $confRes.error
    quit(QuitFailure)

  var conf = confRes.get()

  let twnClusterConf = ClusterConf.TheWakuNetworkConf()
  if len(conf.shards) != 0:
    conf.pubsubTopics = conf.shards.mapIt(twnClusterConf.pubsubTopics[it.uint16])
  else:
    conf.pubsubTopics = twnClusterConf.pubsubTopics

  # Override configuration
  conf.maxMessageSize = twnClusterConf.maxMessageSize
  conf.clusterId = twnClusterConf.clusterId
  conf.rlnRelay = twnClusterConf.rlnRelay
  conf.rlnRelayEthContractAddress = twnClusterConf.rlnRelayEthContractAddress
  conf.rlnRelayDynamic = twnClusterConf.rlnRelayDynamic
  conf.rlnRelayBandwidthThreshold = twnClusterConf.rlnRelayBandwidthThreshold
  conf.discv5Discovery = twnClusterConf.discv5Discovery
  conf.discv5BootstrapNodes =
    conf.discv5BootstrapNodes & twnClusterConf.discv5BootstrapNodes
  conf.rlnEpochSizeSec = twnClusterConf.rlnEpochSizeSec
  conf.rlnRelayUserMessageLimit = twnClusterConf.rlnRelayUserMessageLimit

  debug "Starting node"
  var waku = Waku.init(conf).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  (waitFor startWaku(addr waku)).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  # set triggerSelf to false, we don't want to process our own stealthCommitments
  waku.node.wakuRelay.triggerSelf = false

  info "Node setup complete"
  return waku
