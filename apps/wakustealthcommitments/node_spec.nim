when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ../wakunode2/[networks_config, app, external_config]
import  ../../waku/common/logging
import
  std/[options, strutils, os, sequtils],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto

export
  networks_config,
  app,
  logging,
  options, 
  strutils, 
  os, 
  sequtils,
  stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  crypto

proc setup*(): App =
  const versionString = "version / git commit hash: " & app.git_version
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

  var wakunode2 = App.init(rng, conf)
  ## Peer persistence
  let res1 = wakunode2.setupPeerPersistence()
  if res1.isErr():
    error "1/5 Setting up storage failed", error = $res1.error
    quit(QuitFailure)

  debug "2/5 Retrieve dynamic bootstrap nodes"

  let res3 = wakunode2.setupDyamicBootstrapNodes()
  if res3.isErr():
    error "2/5 Retrieving dynamic bootstrap nodes failed", error = $res3.error
    quit(QuitFailure)

  debug "3/5 Initializing node"

  let res4 = wakunode2.setupWakuApp()
  if res4.isErr():
    error "3/5 Initializing node failed", error = $res4.error
    quit(QuitFailure)

  debug "4/5 Mounting protocols"

  var res5: Result[void, string]
  try:
    res5 = waitFor wakunode2.setupAndMountProtocols()
    if res5.isErr():
      error "4/5 Mounting protocols failed", error = $res5.error
      quit(QuitFailure)
  except Exception:
    error "4/5 Mounting protocols failed", error = getCurrentExceptionMsg()
    quit(QuitFailure)

  debug "5/5 Starting node and mounted protocols"

  let res6 = wakunode2.startApp()
  if res6.isErr():
    error "5/5 Starting node and protocols failed", error = $res6.error
    quit(QuitFailure)

  info "Node setup complete"
  return wakunode2
