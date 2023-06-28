when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables,strutils,times,sequtils],
  stew/results,
  stew/shims/net,
  chronicles,
  chronicles/topics_registry,
  chronos,
  chronos/timer as ctime,
  confutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/nameresolving/dnsresolver,
  metrics,
  metrics/chronos_httpserver,
  presto/[route, server, client]
import
  ../../waku/v2/waku_core,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/waku_node,
  ../../waku/v2/waku_enr,
  ../../waku/v2/waku_discv5,
  ../../waku/v2/waku_dnsdisc,
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

# TODO: Split in discover, connect
proc setConnectedPeersMetrics(discoveredNodes: seq[Node],
                              node: WakuNode,
                              timeout: chronos.Duration,
                              restClient: RestClientRef,
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

    let peer = toRemotePeerInfo(discNode.record)
    if not peer.isOk():
      warn "error converting record to remote peer info", record=discNode.record
      continue

    # try to connect to the peer
    # TODO: check last connection time and if not > x, skip connecting
    let timedOut = not await node.connectToNodes(@[peer.get()]).withTimeout(timeout)
    if timedOut:
      warn "could not connect to peer, timedout", timeout=timeout, peer=peer.get()
      # TODO: Add other staates
      allPeers[peerId].connError = "timedout"
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

proc populateInfoFromIp(allPeersRef: CustomPeersTableRef,
                        restClient: RestClientRef) {.async.} =
  for peer in allPeersRef.keys():
    if allPeersRef[peer].country != "" and allPeersRef[peer].city != "":
      continue
    # TODO: Update also if last update > x
    if allPeersRef[peer].ip == "":
      continue
    # get more info the peers from its ip address
    var location: NodeLocation
    try:
      # IP-API endpoints are now limited to 45 HTTP requests per minute
      await sleepAsync(1400.millis)
      let response = await restClient.ipToLocation(allPeersRef[peer].ip)
      location = response.data
    except CatchableError:
      warn "could not get location", ip=allPeersRef[peer].ip
      continue
    allPeersRef[peer].country = location.country
    allPeersRef[peer].city = location.city

# TODO: Split in discovery, connections, and ip2location
# crawls the network discovering peers and trying to connect to them
# metrics are processed and exposed
proc crawlNetwork(node: WakuNode,
                  wakuDiscv5: WakuDiscoveryV5,
                  restClient: RestClientRef,
                  conf: NetworkMonitorConf,
                  allPeersRef: CustomPeersTableRef) {.async.} =

  let crawlInterval = conf.refreshInterval * 1000
  while true:
    # discover new random nodes
    let discoveredNodes = await wakuDiscv5.protocol.queryRandom()

    # nodes are nested into bucket, flat it
    let flatNodes = wakuDiscv5.protocol.routingTable.buckets.mapIt(it.nodes).flatten()

    # populate metrics related to capabilities as advertised by the ENR (see waku field)
    setDiscoveredPeersCapabilities(flatNodes)

    # tries to connect to all newly discovered nodes
    # and populates metrics related to peers we could connect
    # note random discovered nodes can be already known
    await setConnectedPeersMetrics(discoveredNodes, node, conf.timeout, restClient, allPeersRef)

    # populate info from ip addresses
    await populateInfoFromIp(allPeersRef, restClient)

    let totalNodes = flatNodes.len
    let seenNodes = flatNodes.countIt(it.seen)

    info "discovered nodes: ", total=totalNodes, seen=seenNodes

    # Notes:
    # we dont run ipMajorityLoop
    # we dont run revalidateLoop

    await sleepAsync(crawlInterval.millis)

proc retrieveDynamicBootstrapNodes(dnsDiscovery: bool, dnsDiscoveryUrl: string, dnsDiscoveryNameServers: seq[ValidIpAddress]): Result[seq[RemotePeerInfo], string] =
  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url=dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

proc getBootstrapFromDiscDns(conf: NetworkMonitorConf): Result[seq[enr.Record], string] =
  try:
    let dnsNameServers = @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")]
    let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(true, conf.dnsDiscoveryUrl, dnsNameServers)
    if not dynamicBootstrapNodesRes.isOk():
      error("failed discovering peers from DNS")
    let dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

    # select dynamic bootstrap nodes that have an ENR containing a udp port.
    # Discv5 only supports UDP https://github.com/ethereum/devp2p/blob/master/discv5/discv5-theory.md)
    var discv5BootstrapEnrs: seq[enr.Record]
    for n in dynamicBootstrapNodes:
      if n.enr.isSome():
        let
          enr = n.enr.get()
          tenrRes = enr.toTypedRecord()
        if tenrRes.isOk() and (tenrRes.get().udp.isSome() or tenrRes.get().udp6.isSome()):
          discv5BootstrapEnrs.add(enr)
    return ok(discv5BootstrapEnrs)
  except CatchableError:
    error("failed discovering peers from DNS")

proc initAndStartApp(conf: NetworkMonitorConf): Result[(WakuNode, WakuDiscoveryV5), string] =
  let bindIp = try:
    ValidIpAddress.init("0.0.0.0")
  except CatchableError:
    return err("could not start node: " & getCurrentExceptionMsg())

  let extIp = try:
    ValidIpAddress.init("127.0.0.1")
  except CatchableError:
    return err("could not start node: " & getCurrentExceptionMsg())

  let
    # some hardcoded parameters
    rng = keys.newRng()
    key = crypto.PrivateKey.random(Secp256k1, rng[])[]
    nodeTcpPort = Port(60000)
    nodeUdpPort = Port(9000)
    flags = CapabilitiesBitfield.init(lightpush = false, filter = false, store = false, relay = true)

  var builder = EnrBuilder.init(key)

  builder.withIpAddressAndPorts(
      ipAddr = some(extIp),
      tcpPort = some(nodeTcpPort),
      udpPort = some(nodeUdpPort),
  )
  builder.withWakuCapabilities(flags)

  let recordRes = builder.build()
  let record =
    if recordRes.isErr():
      return err("cannot build record: " & $recordRes.error)
    else: recordRes.get()

  var nodeBuilder = WakuNodeBuilder.init()

  nodeBuilder.withNodeKey(key)
  nodeBuilder.withRecord(record)
  let res = nodeBuilder.withNetworkConfigurationDetails(bindIp, nodeTcpPort)
  if res.isErr():
    return err("node building error" & $res.error)

  let nodeRes = nodeBuilder.build()
  let node =
    if nodeRes.isErr():
      return err("node building error" & $res.error)
    else: nodeRes.get()

  var discv5BootstrapEnrsRes = getBootstrapFromDiscDns(conf)
  if discv5BootstrapEnrsRes.isErr():
    error("failed discovering peers from DNS")
  var discv5BootstrapEnrs = discv5BootstrapEnrsRes.get()

  # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
  for enrUri in conf.bootstrapNodes:
    addBootstrapNode(enrUri, discv5BootstrapEnrs)

  # discv5
  let discv5Conf = WakuDiscoveryV5Config(
    discv5Config: none(DiscoveryConfig),
    address: bindIp,
    port: nodeUdpPort,
    privateKey: keys.PrivateKey(key.skkey),
    bootstrapRecords: discv5BootstrapEnrs,
    autoupdateRecord: false
  )

  let wakuDiscv5 = WakuDiscoveryV5.new(node.rng, discv5Conf, some(record))

  try:
    wakuDiscv5.protocol.open()
  except CatchableError:
    return err("could not start node: " & getCurrentExceptionMsg())

  ok((node, wakuDiscv5))

proc startRestApiServer(conf: NetworkMonitorConf,
                        allPeersInfo: CustomPeersTableRef,
                        numMessagesPerContentTopic: ContentTopicMessageTableRef
                        ): Result[void, string] =
  try:
    let serverAddress = initTAddress(conf.metricsRestAddress & ":" & $conf.metricsRestPort)
    proc validate(pattern: string, value: string): int =
      if pattern.startsWith("{") and pattern.endsWith("}"): 0
      else: 1
    var router = RestRouter.init(validate)
    router.installHandler(allPeersInfo, numMessagesPerContentTopic)
    var sres = RestServerRef.new(router, serverAddress)
    let restServer = sres.get()
    restServer.start()
  except CatchableError:
    error("could not start rest api server")
  ok()

# handles rx of messages over a topic (see subscribe)
# counts the number of messages per content topic
proc subscribeAndHandleMessages(node: WakuNode,
                                pubsubTopic: PubsubTopic,
                                msgPerContentTopic: ContentTopicMessageTableRef) =

  # handle function
  proc handler(pubsubTopic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    trace "rx message", pubsubTopic=pubsubTopic, contentTopic=msg.contentTopic

    # If we reach a table limit size, remove c topics with the least messages.
    let tableSize = 100
    if msgPerContentTopic.len > (tableSize - 1):
      let minIndex = toSeq(msgPerContentTopic.values()).minIndex()
      msgPerContentTopic.del(toSeq(msgPerContentTopic.keys())[minIndex])

    # TODO: Will overflow at some point
    # +1 if content topic existed, init to 1 otherwise
    if msgPerContentTopic.hasKey(msg.contentTopic):
      msgPerContentTopic[msg.contentTopic] += 1
    else:
      msgPerContentTopic[msg.contentTopic] = 1

  node.subscribe(pubsubTopic, handler)

when isMainModule:
  # known issue: confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
  {.pop.}
  let confRes = NetworkMonitorConf.loadConfig()
  if confRes.isErr():
    error "could not load cli variables", err=confRes.error
    quit(1)

  let conf = confRes.get()
  info "cli flags", conf=conf

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  # list of peers that we have discovered/connected
  var allPeersInfo = CustomPeersTableRef()

  # content topic and the number of messages that were received
  var msgPerContentTopic = ContentTopicMessageTableRef()

  # start metrics server
  if conf.metricsServer:
    let res = startMetricsServer(conf.metricsServerAddress, Port(conf.metricsServerPort))
    if res.isErr():
      error "could not start metrics server", err=res.error
      quit(1)

  # start rest server for custom metrics
  let res = startRestApiServer(conf, allPeersInfo, msgPerContentTopic)
  if res.isErr():
    error "could not start rest api server", err=res.error
    quit(1)

  # create a rest client
  let clientRest = RestClientRef.new(url="http://ip-api.com",
                                     connectTimeout=ctime.seconds(2))
  if clientRest.isErr():
    error "could not start rest api client", err=res.error
    quit(1)
  let restClient = clientRest.get()

  # start waku node
  let nodeRes = initAndStartApp(conf)
  if nodeRes.isErr():
    error "could not start node"
    quit 1

  let (node, discv5) = nodeRes.get()

  waitFor node.mountRelay()

  # Subscribe the node to the default pubsubtopic, to count messages
  subscribeAndHandleMessages(node, DefaultPubsubTopic, msgPerContentTopic)

  # spawn the routine that crawls the network
  # TODO: split into 3 routines (discovery, connections, ip2location)
  asyncSpawn crawlNetwork(node, discv5, restClient, conf, allPeersInfo)

  runForever()
