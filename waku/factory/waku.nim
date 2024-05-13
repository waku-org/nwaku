when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  chronicles,
  chronos,
  libp2p/wire,
  libp2p/multicodec,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/peerid,
  eth/keys,
  presto,
  metrics,
  metrics/chronos_httpserver
import
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/node/peer_manager,
  ../../waku/node/health_monitor,
  ../../waku/waku_api/message_cache,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_archive,
  ../../waku/discovery/waku_dnsdisc,
  ../../waku/discovery/waku_discv5,
  ../../waku/waku_enr/sharding,
  ../../waku/waku_rln_relay,
  ../../waku/waku_store,
  ../../waku/waku_filter_v2,
  ../../waku/factory/node_factory,
  ../../waku/factory/internal_config,
  ../../waku/factory/external_config

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type Waku* = object
  version: string
  conf: WakuNodeConf
  rng: ref HmacDrbgContext
  key: crypto.PrivateKey

  wakuDiscv5*: WakuDiscoveryV5
  dynamicBootstrapNodes: seq[RemotePeerInfo]

  node*: WakuNode

  restServer*: WakuRestServerRef
  metricsServer*: MetricsHttpServerRef

func version*(waku: Waku): string =
  waku.version

## Initialisation

proc init*(T: type Waku, conf: WakuNodeConf): Result[Waku, string] =
  var confCopy = conf
  let rng = crypto.newRng()

  if not confCopy.nodekey.isSome():
    let keyRes = crypto.PrivateKey.random(Secp256k1, rng[])
    if keyRes.isErr():
      error "Failed to generate key", error = $keyRes.error
      return err("Failed to generate key: " & $keyRes.error)
    confCopy.nodekey = some(keyRes.get())

  debug "Retrieve dynamic bootstrap nodes"
  let dynamicBootstrapNodesRes = waku_dnsdisc.retrieveDynamicBootstrapNodes(
    confCopy.dnsDiscovery, confCopy.dnsDiscoveryUrl, confCopy.dnsDiscoveryNameServers
  )
  if dynamicBootstrapNodesRes.isErr():
    error "Retrieving dynamic bootstrap nodes failed",
      error = dynamicBootstrapNodesRes.error
    return err(
      "Retrieving dynamic bootstrap nodes failed: " & dynamicBootstrapNodesRes.error
    )

  let nodeRes = setupNode(confCopy, some(rng))
  if nodeRes.isErr():
    error "Failed setting up node", error = nodeRes.error
    return err("Failed setting up node: " & nodeRes.error)

  var waku = Waku(
    version: git_version,
    conf: confCopy,
    rng: rng,
    key: confCopy.nodekey.get(),
    node: nodeRes.get(),
    dynamicBootstrapNodes: dynamicBootstrapNodesRes.get(),
  )

  ok(waku)

proc getPorts(
    listenAddrs: seq[MultiAddress]
): Result[tuple[tcpPort, websocketPort: Option[Port]], string] =
  var tcpPort, websocketPort = none(Port)

  for a in listenAddrs:
    if a.isWsAddress():
      if websocketPort.isNone():
        let wsAddress = initTAddress(a).valueOr:
          return err("getPorts wsAddr error:" & $error)
        websocketPort = some(wsAddress.port)
    elif tcpPort.isNone():
      let tcpAddress = initTAddress(a).valueOr:
        return err("getPorts tcpAddr error:" & $error)
      tcpPort = some(tcpAddress.port)

  return ok((tcpPort: tcpPort, websocketPort: websocketPort))

proc getRunningNetConfig(waku: ptr Waku): Result[NetConfig, string] =
  var conf = waku[].conf
  let (tcpPort, websocketPort) = getPorts(waku[].node.switch.peerInfo.listenAddrs).valueOr:
    return err("Could not retrieve ports " & error)

  if tcpPort.isSome():
    conf.tcpPort = tcpPort.get()

  if websocketPort.isSome():
    conf.websocketPort = websocketPort.get()

  # Rebuild NetConfig with bound port values
  let netConf = networkConfiguration(conf, clientId).valueOr:
    return err("Could not update NetConfig: " & error)

  return ok(netConf)

proc updateEnr(waku: ptr Waku, netConf: NetConfig): Result[void, string] =
  let record = enrConfiguration(waku[].conf, netConf, waku[].key).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, waku[].conf.clusterId):
    return err("cluster id mismatch configured shards")

  waku[].node.enr = record

  return ok()

proc updateWaku(waku: ptr Waku): Result[void, string] =
  if waku[].conf.tcpPort == Port(0) or waku[].conf.websocketPort == Port(0):
    let netConf = getRunningNetConfig(waku).valueOr:
      return err("error calling updateNetConfig: " & $error)

    updateEnr(waku, netConf).isOkOr:
      return err("error calling updateEnr: " & $error)

    waku[].node.announcedAddresses = netConf.announcedAddresses

    printNodeNetworkInfo(waku[].node)

  return ok()

proc startWaku*(waku: ptr Waku): Future[Result[void, string]] {.async: (raises: []).} =
  (await startNode(waku.node, waku.conf, waku.dynamicBootstrapNodes)).isOkOr:
    return err("error while calling startNode: " & $error)

  # Update waku data that is set dynamically on node start
  updateWaku(waku).isOkOr:
    return err("Error in updateApp: " & $error)

  ## Discv5
  if waku[].conf.discv5Discovery:
    waku[].wakuDiscV5 = waku_discv5.setupDiscoveryV5(
      waku.node.enr, waku.node.peerManager, waku.node.topicSubscriptionQueue, waku.conf,
      waku.dynamicBootstrapNodes, waku.rng, waku.key,
    )

    (await waku.wakuDiscV5.start()).isOkOr:
      return err("failed to start waku discovery v5: " & $error)

  return ok()

# Waku shutdown

proc stop*(waku: Waku): Future[void] {.async: (raises: [Exception]).} =
  if not waku.restServer.isNil():
    await waku.restServer.stop()

  if not waku.metricsServer.isNil():
    await waku.metricsServer.stop()

  if not waku.wakuDiscv5.isNil():
    await waku.wakuDiscv5.stop()

  if not waku.node.isNil():
    await waku.node.stop()
