{.push raises: [].}

import tools/confutils/cli_args
import logos_delivery/kernel/[base/logging, kernel_lifecycle, config/networks_config]
import
  results,
  std/[strutils, os, sequtils],
  chronicles,
  chronos,
  metrics,
  libp2p/crypto/crypto

export
  networks_config, kernel_lifecycle, logging, strutils, os, sequtils, stewNet,
  chronicles, chronos, metrics, crypto

proc setup*(): Kernel =
  const versionString = "version / git commit hash: " & kernel_lifecycle.git_version
  let rng = crypto.newRng()

  let conf = WakuNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = $error
    quit(QuitFailure)

  let twnNetworkConf = NetworkPresetConf.TheWakuNetworkConf()
  if len(conf.shards) != 0:
    conf.pubsubTopics = conf.shards.mapIt(twnNetworkConf.pubsubTopics[it.uint16])
  else:
    conf.pubsubTopics = twnNetworkConf.pubsubTopics

  # Override configuration
  conf.maxMessageSize = twnNetworkConf.maxMessageSize
  conf.clusterId = Opt.some(twnNetworkConf.clusterId)
  conf.rlnRelayEthContractAddress = twnNetworkConf.rlnRelayEthContractAddress
  conf.rlnRelayDynamic = Opt.some(twnNetworkConf.rlnRelayDynamic)
  conf.discv5Discovery = Opt.some(twnNetworkConf.discv5Discovery)
  conf.discv5BootstrapNodes =
    conf.discv5BootstrapNodes & twnNetworkConf.discv5BootstrapNodes
  conf.rlnEpochSizeSec = Opt.some(twnNetworkConf.rlnEpochSizeSec)
  conf.rlnRelayUserMessageLimit = Opt.some(twnNetworkConf.rlnRelayUserMessageLimit)

  # Only set rlnRelay to true if relay is configured
  if conf.relay:
    conf.rlnRelay = Opt.some(twnNetworkConf.rlnRelay)

  info "Starting node"
  var kernel = (waitFor Kernel.new(conf)).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  (waitFor kernel.start()).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  # set triggerSelf to false, we don't want to process our own stealthCommitments
  kernel.protocols.relay.triggerSelf = false

  info "Node setup complete"
  return kernel
