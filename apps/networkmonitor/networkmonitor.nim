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
  libp2p/protocols/ping,
  metrics,
  metrics/chronos_httpserver,
  presto/[route, server, client]
import
  ../../waku/waku_core,
  ../../waku/node/peer_manager,
  ../../waku/waku_node,
  ../../waku/waku_enr,
  ../../waku/waku_discv5,
  ../../waku/waku_dnsdisc,
  ./networkmonitor_metrics,
  ./networkmonitor_config,
  ./networkmonitor_utils

logScope:
  topics = "networkmonitor"

const ReconnectTime = 60
const MaxConnectionRetries = 5
const ResetRetriesAfter = 1200
const AvgPingWindow = 10.0

const git_version* {.strdefine.} = "n/a"

proc setDiscoveredPeersCapabilities(
  routingTableNodes: seq[Node]) =
  for capability in @[Relay, Store, Filter, Lightpush]:
    let nOfNodesWithCapability = routingTableNodes.countIt(it.record.supportsCapability(capability))
    info "capabilities as per ENR waku flag", capability=capability, amount=nOfNodesWithCapability
    networkmonitor_peer_type_as_per_enr.set(int64(nOfNodesWithCapability), labelValues = [$capability])

proc analyzePeer(
      customPeerInfo: CustomPeerInfoRef,
      peerInfo: RemotePeerInfo,
      node: WakuNode,
      timeout: chronos.Duration
    ): Future[Result[string, string]] {.async.} =
  var pingDelay: chronos.Duration

  proc ping(): Future[Result[void, string]] {.async, gcsafe.} =
    try:
      let conn = await node.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
      pingDelay = await node.libp2pPing.ping(conn)
      return ok()

    except CatchableError:
      var msg = getCurrentExceptionMsg()
      if msg == "Future operation cancelled!":
        msg = "timedout"
      warn "failed to ping the peer", peer=peerInfo, err=msg

      customPeerInfo.connError = msg
      return err("could not ping peer: " & msg)

  let timedOut = not await ping().withTimeout(timeout)
  # need this check for pingDelat == 0 because there may be a conn error before timeout
  if timedOut or pingDelay == 0.millis:
    customPeerInfo.retries += 1
    return err(customPeerInfo.connError)

  customPeerInfo.connError = ""
  info "successfully pinged peer", peer=peerInfo, duration=pingDelay.millis
  networkmonitor_peer_ping.observe(pingDelay.millis)

  if customPeerInfo.avgPingDuration == 0.millis:
    customPeerInfo.avgPingDuration = pingDelay

  # TODO: check why the calculation ends up losing precision
  customPeerInfo.avgPingDuration = int64((float64(customPeerInfo.avgPingDuration.millis) * (AvgPingWindow - 1.0) + float64(pingDelay.millis)) / AvgPingWindow).millis
  customPeerInfo.lastPingDuration = pingDelay

  return ok(customPeerInfo.peerId)

proc shouldReconnect(customPeerInfo: CustomPeerInfoRef): bool =
  let reconnetIntervalCheck = getTime().toUnix() >= customPeerInfo.lastTimeConnected + ReconnectTime
  var retriesCheck = customPeerInfo.retries < MaxConnectionRetries

  if not retriesCheck and getTime().toUnix() >= customPeerInfo.lastTimeConnected + ResetRetriesAfter:
    customPeerInfo.retries = 0
    retriesCheck = true
    info "resetting retries counter", peerId=customPeerInfo.peerId

  return reconnetIntervalCheck and retriesCheck

# TODO: Split in discover, connect
proc setConnectedPeersMetrics(discoveredNodes: seq[Node],
                              node: WakuNode,
                              timeout: chronos.Duration,
                              restClient: RestClientRef,
                              allPeers: CustomPeersTableRef) {.async.} =

  let currentTime = getTime().toUnix()

  var newPeers = 0
  var successfulConnections = 0

  var analyzeFuts: seq[Future[Result[string, string]]]

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

    let peerRes = toRemotePeerInfo(discNode.record)

    let peerInfo = peerRes.valueOr():
      warn "error converting record to remote peer info", record=discNode.record
      continue

    # create new entry if new peerId found
    let peerId = $peerInfo.peerId

    if not allPeers.hasKey(peerId):
      allPeers[peerId] = CustomPeerInfoRef(peerId: peerId)
      newPeers += 1
    else:
      info "already seen", peerId=peerId

    let customPeerInfo = allPeers[peerId]

    customPeerInfo.lastTimeDiscovered = currentTime
    customPeerInfo.enr = discNode.record.toURI()
    customPeerInfo.enrCapabilities = discNode.record.getCapabilities().mapIt($it)
    customPeerInfo.discovered += 1

    if not typedRecord.get().ip.isSome():
      warn "ip field is not set", record=typedRecord.get()
      continue

    let ip = $typedRecord.get().ip.get().join(".")
    customPeerInfo.ip = ip

    # try to ping the peer
    if shouldReconnect(customPeerInfo):
      if customPeerInfo.retries > 0:
        warn "trying to dial failed peer again", peerId=peerId, retry=customPeerInfo.retries
      analyzeFuts.add(analyzePeer(customPeerInfo, peerInfo, node, timeout))

  # Wait for all connection attempts to finish
  let analyzedPeers = await allFinished(analyzeFuts)

  for peerIdFut in analyzedPeers:
    let peerIdRes = await peerIdFut
    let peerIdStr = peerIdRes.valueOr():
      continue

    successfulConnections += 1
    let peerId = PeerId.init(peerIdStr).valueOr():
      warn "failed to parse peerId", peerId=peerIdStr
      continue
    var customPeerInfo = allPeers[peerIdStr]

    debug "connected to peer", peer=customPeerInfo[]

    # after connection, get supported protocols
    let lp2pPeerStore = node.switch.peerStore
    let nodeProtocols = lp2pPeerStore[ProtoBook][peerId]
    customPeerInfo.supportedProtocols = nodeProtocols
    customPeerInfo.lastTimeConnected = currentTime

    # after connection, get user-agent
    let nodeUserAgent = lp2pPeerStore[AgentBook][peerId]
    customPeerInfo.userAgent = nodeUserAgent

  info "number of newly discovered peers", amount=newPeers
  # inform the total connections that we did in this round
  info "number of successful connections", amount=successfulConnections

proc updateMetrics(allPeersRef: CustomPeersTableRef) {.gcsafe.} =
  var allProtocols: Table[string, int]
  var allAgentStrings: Table[string, int]
  var countries: Table[string, int]
  var connectedPeers = 0
  var failedPeers = 0

  for peerInfo in allPeersRef.values:
    if peerInfo.connError == "":
      for protocol in peerInfo.supportedProtocols:
        allProtocols[protocol] = allProtocols.mgetOrPut(protocol, 0) + 1

    # store available user-agents in the network
      allAgentStrings[peerInfo.userAgent] = allAgentStrings.mgetOrPut(peerInfo.userAgent, 0) + 1

      if peerInfo.country != "":
        countries[peerInfo.country] = countries.mgetOrPut(peerInfo.country, 0) + 1

      connectedPeers += 1
    else:
      failedPeers += 1

  networkmonitor_peer_count.set(int64(connectedPeers), labelValues = ["true"])
  networkmonitor_peer_count.set(int64(failedPeers), labelValues = ["false"])
   # update count on each protocol
  for protocol in allProtocols.keys():
    let countOfProtocols = allProtocols.mgetOrPut(protocol, 0)
    networkmonitor_peer_type_as_per_protocol.set(int64(countOfProtocols), labelValues = [protocol])
    info "supported protocols in the network", protocol=protocol, count=countOfProtocols

  # update count on each user-agent
  for userAgent in allAgentStrings.keys():
    let countOfUserAgent = allAgentStrings.mgetOrPut(userAgent, 0)
    networkmonitor_peer_user_agents.set(int64(countOfUserAgent), labelValues = [userAgent])
    info "user agents participating in the network", userAgent=userAgent, count=countOfUserAgent

  for country in countries.keys():
    let peerCount = countries.mgetOrPut(country, 0)
    networkmonitor_peer_country_count.set(int64(peerCount), labelValues = [country])
    info "number of peers per country", country=country, count=peerCount

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
    let startTime = Moment.now()
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

    updateMetrics(allPeersRef)

    # populate info from ip addresses
    await populateInfoFromIp(allPeersRef, restClient)

    let totalNodes = flatNodes.len
    let seenNodes = flatNodes.countIt(it.seen)

    info "discovered nodes: ", total=totalNodes, seen=seenNodes

    # Notes:
    # we dont run ipMajorityLoop
    # we dont run revalidateLoop
    let endTime = Moment.now()
    let elapsed = (endTime - startTime).nanos

    info "crawl duration", time=elapsed.millis

    await sleepAsync(crawlInterval.millis - elapsed.millis)

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

  node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(handler))

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
  waitFor node.mountLibp2pPing()

  # Subscribe the node to the default pubsubtopic, to count messages
  subscribeAndHandleMessages(node, DefaultPubsubTopic, msgPerContentTopic)

  # spawn the routine that crawls the network
  # TODO: split into 3 routines (discovery, connections, ip2location)
  asyncSpawn crawlNetwork(node, discv5, restClient, conf, allPeersInfo)

  runForever()
