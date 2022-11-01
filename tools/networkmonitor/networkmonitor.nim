import
  confutils,
  std/[tables,strutils,times,sequtils,httpclient],
  chronicles,
  chronicles/topics_registry,
  chronos,
  stew/shims/net,
  presto/[route, server],
  metrics,
  metrics/chronos_httpserver,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/utils/wakuenr,
  ../../waku/v2/utils/peers,
  ./networkmonitor_metrics,
  ./networkmonitor_config,
  ./networkmonitor_utils

logScope:
  topics = "networkmonitor"

proc setDiscoveredPeersCapabilities(
  routingTableNodes: seq[Node]) =
  for capability in @[Relay, Store, Filter, Lightpush]:
    let nOfNodesWithCapability = routingTableNodes.countIt(it.record.supportsCapability(capability))
    info "capabilities as per ENR waku flag", capability=capability, amount=nOfNodesWithCapability
    peer_type_as_per_enr.set(int64(nOfNodesWithCapability), labelValues = [$capability])

proc setConnectedPeersMetrics(discoveredNodes: seq[Node],
                              node: WakuNode,
                              timeout: chronos.Duration,
                              client: HttpClient,
                              allPeers: CustomPeersTableRef) {.async.} =

  let currentTime = $getTime()

  # Protocols and agent string and its count
  var allProtocols: Table[string, int]
  var allAgentStrings: Table[string, int]

  # iterate all newly discovered nodes
  for discNode in discoveredNodes:
    let typedRecord = discNode.record.toTypedRecord()
    if not typedRecord.isOk():
      warn "could not convert record to typed record", record=discNode.record
      continue

    let secp256k1 = typedRecord.get().secp256k1
    if not secp256k1.isSome():
      warn "could not get secp256k1 key", typedRecord=typedRecord.get()
      continue

    # create new entry if new peerId found
    let peerId = secp256k1.get().toHex()
    let customPeerInfo = CustomPeerInfo(peerId: peerId)
    if not allPeers.hasKey(peerId):
      allPeers[peerId] = customPeerInfo

    allPeers[peerId].lastTimeDiscovered = currentTime
    allPeers[peerId].enr = discNode.record.toURI()
    allPeers[peerId].enrCapabilities = discNode.record.getCapabilities().mapIt($it)

    if not typedRecord.get().ip.isSome():
      warn "ip field is not set", record=typedRecord.get()
      continue

    let ip = $typedRecord.get().ip.get().join(".")
    allPeers[peerId].ip = ip

    # get more info the peers from its ip address
    let location = await ipToLocation(ip, client)
    if not location.isOk():
      warn "could not get location", ip=ip
      continue

    allPeers[peerId].country = location.get().country
    allPeers[peerId].city = location.get().city
          
    let peer = toRemotePeerInfo(discNode.record)
    if not peer.isOk():
      warn "error converting record to remote peer info", record=discNode.record
      continue

    # try to connect to the peer
    let timedOut = not await node.connectToNodes(@[peer.get()]).withTimeout(timeout)
    if timedOut:
      warn "could not connect to peer, timedout", timeout=timeout, peer=peer.get()
      continue

    # after connection, get supported protocols
    let lp2pPeerStore = node.switch.peerStore
    let nodeProtocols = lp2pPeerStore[ProtoBook][peer.get().peerId]
    allPeers[peerId].supportedProtocols = nodeProtocols
    allPeers[peerId].lastTimeConnected = currentTime

    # after connection, get user-agent
    let nodeUserAgent = lp2pPeerStore[AgentBook][peer.get().peerId]
    allPeers[peerId].userAgent = nodeUserAgent

    # store avaiable protocols in the network
    for protocol in nodeProtocols:
      if not allProtocols.hasKey(protocol):
        allProtocols[protocol] = 0
      allProtocols[protocol] += 1

    # store available user-agents in the network
    if not allAgentStrings.hasKey(nodeUserAgent):
      allAgentStrings[nodeUserAgent] = 0
    allAgentStrings[nodeUserAgent] += 1

    debug "connected to peer", peer=allPeers[customPeerInfo.peerId]
   
  # inform the total connections that we did in this round
  let nOfOkConnections = allProtocols.len()
  info "number of successful connections", amount=nOfOkConnections

  # update count on each protocol
  for protocol in allProtocols.keys():
    let countOfProtocols = allProtocols[protocol]
    peer_type_as_per_protocol.set(int64(countOfProtocols), labelValues = [protocol])
    info "supported protocols in the network", protocol=protocol, count=countOfProtocols

  # update count on each user-agent
  for userAgent in allAgentStrings.keys():
    let countOfUserAgent = allAgentStrings[userAgent]
    peer_user_agents.set(int64(countOfUserAgent), labelValues = [userAgent])
    info "user agents participating in the network", userAgent=userAgent, count=countOfUserAgent

proc main() {.async.} = 
  let conf: NetworkMonitorConf = NetworkMonitorConf.load()

  info "cli flags", conf=conf

  # TODO: Run sanity checks on cli flags, i.e. bootstrap nodes

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  if conf.metricsServer:
    startMetricsServer(
      conf.metricsServerAddress,
      Port(conf.metricsServerPort))

  let client = newHttpClient()

  let
    rng = keys.newRng()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
    nodeTcpPort1 = Port(60000)
    nodeUdpPort1 = Port(9000)
    node = WakuNode.new(
      nodeKey1,
      bindIp,
      nodeTcpPort1)
    
    # TODO: Propose refactor removing initWakuFlags
    flags = initWakuFlags(lightpush = false,
                          filter = false,
                          store = false,
                          relay = true)

  # TODO: use other discovery mechanisms: i.e. dns
  
  # mount discv5
  node.wakuDiscv5 = WakuDiscoveryV5.new(
      some(extIp), some(nodeTcpPort1), some(nodeUdpPort1),
      bindIp,
      nodeUdpPort1,
      conf.bootstrapNodes,
      false,
      keys.PrivateKey(nodeKey1.skkey),
      flags,
      [],
      node.rng
    )

  let d = node.wakuDiscv5.protocol
  d.open()

  # list of peers that we have discovered/connected
  var allPeersRef = CustomPeersTableRef()

  let serverAddress = initTAddress(conf.metricsRestAddress & ":" & $conf.metricsRestPort)
  proc validate(pattern: string, value: string): int =
    if pattern.startsWith("{") and pattern.endsWith("}"): 0
    else: 1
  var router = RestRouter.init(validate)
  router.installHandler(allPeersRef)

  # rest server for custom metrics
  var sres = RestServerRef.new(router, serverAddress)
  let restServer = sres.get()
  restServer.start()

  while true:
    # discover new random nodes
    let discoveredNodes = await d.queryRandom()

    # nodes are nested into bucket, flat it
    let flatNodes = d.routingTable.buckets.mapIt(it.nodes).flatten()

    # populate metrics related to capabilities as advertised by the ENR (see waku field)
    setDiscoveredPeersCapabilities(flatNodes)

    # tries to connect to all newly discovered nodes
    # and populates metrics related to peers we could connect
    # note random discovered nodes can be already known
    await setConnectedPeersMetrics(discoveredNodes, node, conf.timeout, client, allPeersRef)

    let totalNodes = flatNodes.len
    let seenNodes = flatNodes.countIt(it.seen)

    info "discovered nodes: ", total=totalNodes, seen=seenNodes

    # Notes:
    # we dont run ipMajorityLoop
    # we dont run revalidateLoop

    await sleepAsync(conf.refreshInterval * 1000 * 60)

when isMainModule:
  waitFor main()