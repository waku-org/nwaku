when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables,strutils,times,sequtils,httpclient],
  chronicles,
  chronicles/topics_registry,
  chronos,
  confutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  metrics,
  metrics/chronos_httpserver,
  presto/[route, server],
  stew/shims/net

import
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/utils/wakuenr,
  ../../waku/v2/protocol/waku_message,
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

# TODO: Split in discover, connect, populate ips
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
    # TODO: check last connection time and if not > x, skip connecting
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


# TODO: Split in discovery, connections, and ip2location
# crawls the network discovering peers and trying to connect to them
# metrics are processed and exposed
proc crawlNetwork(node: WakuNode,
                  conf: NetworkMonitorConf,
                  allPeersRef: CustomPeersTableRef) {.async.} = 

  let crawlInterval = conf.refreshInterval * 1000
  let client = newHttpClient()
  while true:
    # discover new random nodes
    let discoveredNodes = await node.wakuDiscv5.protocol.queryRandom()

    # nodes are nested into bucket, flat it
    let flatNodes = node.wakuDiscv5.protocol.routingTable.buckets.mapIt(it.nodes).flatten()

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

    await sleepAsync(crawlInterval)

proc initAndStartNode(conf: NetworkMonitorConf): Result[WakuNode, string] = 
  let
    # some hardcoded parameters
    rng = keys.newRng()
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
    nodeTcpPort = Port(60000)
    nodeUdpPort = Port(9000)
    flags = initWakuFlags(lightpush = false, filter = false, store = false, relay = true)
  
  try:
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")
      node = WakuNode.new(nodeKey, bindIp, nodeTcpPort)

    # mount discv5
    node.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort), some(nodeUdpPort),
        bindIp, nodeUdpPort, conf.bootstrapNodes, false,
        keys.PrivateKey(nodeKey.skkey), flags, [], node.rng)

    node.wakuDiscv5.protocol.open()
    return ok(node)
  except:
    error("could not start node")

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
  except:
    error("could not start rest api server")
  ok()

# handles rx of messages over a topic (see subscribe)
# counts the number of messages per content topic
proc subscribeAndHandleMessages(node: WakuNode,
                                pubsubTopic: PubsubTopic,
                                msgPerContentTopic: ContentTopicMessageTableRef) =
  
  # handle function
  proc handler(pubsubTopic: PubsubTopic, data: seq[byte]) {.async, gcsafe.} =
    let messageRes = WakuMessage.decode(data)
    if messageRes.isErr():
      warn "could not decode message", data=data, pubsubTopic=pubsubTopic

    let message = messageRes.get()
    trace "rx message", pubsubTopic=pubsubTopic, contentTopic=message.contentTopic

    # If we reach a table limit size, remove c topics with the least messages.
    let tableSize = 100
    if msgPerContentTopic.len > (tableSize - 1):
      let minIndex = toSeq(msgPerContentTopic.values()).minIndex()
      msgPerContentTopic.del(toSeq(msgPerContentTopic.keys())[minIndex])

    # TODO: Will overflow at some point
    # +1 if content topic existed, init to 1 otherwise
    if msgPerContentTopic.hasKey(message.contentTopic):
      msgPerContentTopic[message.contentTopic] += 1
    else:
      msgPerContentTopic[message.contentTopic] = 1

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

  # start waku node
  let nodeRes = initAndStartNode(conf)
  if nodeRes.isErr():
    error "could not start node"
    quit 1
  
  let node = nodeRes.get()

  waitFor node.mountRelay()

  # Subscribe the node to the default pubsubtopic, to count messages
  subscribeAndHandleMessages(node, DefaultPubsubTopic, msgPerContentTopic)

  # spawn the routine that crawls the network
  # TODO: split into 3 routines (discovery, connections, ip2location)
  asyncSpawn crawlNetwork(node, conf, allPeersInfo)
  
  runForever()