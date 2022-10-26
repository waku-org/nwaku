# TODO: fix imports
import
  confutils,
  sequtils,
  std/[sugar,tables,strutils,times],
  chronicles,
  chronicles/topics_registry,
  chronos,
  stew/byteutils,
  stew/shims/net,
  metrics,
  metrics/chronos_httpserver,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/utils/wakuenr,
  ../../waku/v2/utils/peers,
  ./networkmonitor_metrics,
  ./networkmonitor_config

logScope:
  topics = "networkmonitor"
        
# TODO: Move to utils
proc flatten*[T](a: seq[seq[T]]): seq[T] =
  result = @[]
  for subseq in a:
    result &= subseq

proc setDiscoveredPeersMetrics(discoveredNodes: seq[Node]) =
  for discNode in discoveredNodes:
    let typedRecord = discNode.record.toTypedRecord()
    if not typedRecord.isOk():
      warn "could not convert record to typed record", record=discNode.record
      continue
    if not typedRecord.get().ip.isSome():
      warn "ip field is not set", record=typedRecord.get()
      continue
    let currentTime = $getTime()
    discovered_peers_list.set(int64(0),
                           labelValues = [discNode.record.toURI(),
                                          $typedRecord.get().ip.get().join("."),
                                          discNode.record.getCapabilities().join(","),
                                          currentTime]) 

proc setDiscoveredPeersCapabilities(routingTableNodes: seq[Node]) =
  for capability in @[Relay, Store, Filter, Lightpush]:
    let nOfNodesWithCapability = routingTableNodes.countIt(it.record.supportsCapability(capability))
    info "capabilities as per ENR waku flag", capability=capability, amount=nOfNodesWithCapability
    peer_type_as_per_enr.set(int64(nOfNodesWithCapability), labelValues = [$capability])

proc setConnectedPeersMetrics(routingTableNodes: seq[Node],
                              node: WakuNode,
                              timeout: chronos.Duration) {.async.} =
  var protocolCount: seq[seq[string]] = @[]
  for discNode in routingTableNodes:
    # ensure record is correct
    let typedRecord = discNode.record.toTypedRecord()
    if not typedRecord.isOk():
      warn "could not convert record to typed record", record=discNode.record
      continue
    if not typedRecord.get().ip.isSome():
      warn "ip field is not set", record=typedRecord.get()
      continue
          
    let peer = toRemotePeerInfo(discNode.record)
    if not peer.isOk():
      warn "error converting record to remote peer info", record=discNode.record
      continue
    let timedOut = not await node.connectToNodes(@[peer.get()]).withTimeout(timeout)
    if timedOut:
      warn "could not connect to peer, timedout", timeout=timeout, peer=peer.get()
      continue

    # after connection, get supported protocols
    let lp2pPeerStore = node.switch.peerStore
    let nodeProtocols = lp2pPeerStore[ProtoBook][peer.get().peerId]

    # store avaiable protocols in the network
    protocolCount &= nodeProtocols

    # update metrics with node info
    let currentTime = $getTime()
    connected_peers_list.set(int64(0),
                           labelValues = [discNode.record.toURI(),
                                          $typedRecord.get().ip.get().join("."),
                                          nodeProtocols.join(","),
                                          currentTime])
    debug "connected to peer", enr=discNode.record.toURI(),
                               ip=typedRecord.get().ip.get().join("."),
                               protocols=nodeProtocols.join(",")
   
  # inform the total connections that we did in this round
  let nOfOkConnections = protocolCount.len()
  info "number of successful connections", amount=nOfOkConnections

  # update count on each protocol
  let allProtocols = protocolCount.flatten()
  for protocol in allProtocols.deduplicate():
    let countOfProtocols = allProtocols.count(protocol)
    peer_type_as_per_protocol.set(int64(countOfProtocols), labelValues = [protocol])
    info "supported protocols in the network", protocol=protocol, count=countOfProtocols

proc main() {.async.} = 
  let conf: NetworkMonitorConf = NetworkMonitorConf.load()

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  if conf.metricsServer:
    startMetricsServer(
      conf.metricsServerAddress,
      Port(conf.metricsServerPort))

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
  
  # TODO: Add flag
  # waku prod bootstrap nodes
  const bootstrapNodes = @[
    # prod
    "enr:-Nm4QOdTOKZJKTUUZ4O_W932CXIET-M9NamewDnL78P5u9DOGnZlK0JFZ4k0inkfe6iY-0JAaJVovZXc575VV3njeiABgmlkgnY0gmlwhAjS3ueKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuYWMtY24taG9uZ2tvbmctYy53YWt1djIucHJvZC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhAo0C-VvfgHiXrxZi3umDiooXMGY9FvYj5_d1Q4EeS7eyg3RjcIJ2X4N1ZHCCIyiFd2FrdTIP",
    "enr:-M-4QLdAB-KyzT3QEsDoNa4LXT6RGH9BIylvTlDFLQhigWmxKEesulgc8AoKmVEUKj_4St6ThBKwyBc69tBfCe2hVTABgmlkgnY0gmlwhLymh5GKbXVsdGlhZGRyc7EALzYobm9kZS0wMS5kby1hbXMzLndha3V2Mi5wcm9kLnN0YXR1c2ltLm5ldAYfQN4DiXNlY3AyNTZrMaEDbl1X_zJIw3EAJGtmHMVn4Z2xhpSoUaP5ElsHKCv7hlWDdGNwgnZfg3VkcIIjKIV3YWt1Mg8",
    "enr:-Nm4QNgc2L6L-4nk6jgllNDE1QDcn6kv2922rTRYs1wM3My_OmSsTimkMCIMh8fat6enFdYfuJ23KjWdF5whBz3zXgUBgmlkgnY0gmlwhCJ5ZGyKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuZ2MtdXMtY2VudHJhbDEtYS53YWt1djIucHJvZC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhA_30kHgQqfXZRioa4J_u5asgXTJ5iw_8w3lEICH4TFu_g3RjcIJ2X4N1ZHCCIyiFd2FrdTIP",
    # test
    "enr:-Nm4QC0_ClHzbsutYzgT3jJm7ZY1D4shylAdd6Ac-L4uwAUha1oHM0zwoEkTORVt94W5Cpa0IiyrTcXAYLgpRXpVNUsBgmlkgnY0gmlwhC_y0kmKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuYWMtY24taG9uZ2tvbmctYy53YWt1djIudGVzdC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhAhAm-P4q6mWONKcGnbLPU8WXZJ4Qs3AxIbrycvc7PVKsg3RjcIJ2X4N1ZHCCIyiFd2FrdTIP",
    "enr:-M-4QCtJKX2WDloRYDT4yjeMGKUCRRcMlsNiZP3cnPO0HZn6IdJ035RPCqsQ5NvTyjqHzKnTM6pc2LoKliV4CeV0WrgBgmlkgnY0gmlwhIbRi9KKbXVsdGlhZGRyc7EALzYobm9kZS0wMS5kby1hbXMzLndha3V2Mi50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DiXNlY3AyNTZrMaEDnr03Tuo77930a7sYLikftxnuG3BbC3gCFhA4632ooDaDdGNwgnZfg3VkcIIjKIV3YWt1Mg8",
    "enr:-Nm4QLHYoJ5WYQoVzyqPR-pwIeQvi3ONWs-EPwk3uUiBiDseN9Dd7fYbCvkMdeXcuZ-8U9IYdGm38VxSDf_Oq3zZ0cEBgmlkgnY0gmlwhGia74CKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuZ2MtdXMtY2VudHJhbDEtYS53YWt1djIudGVzdC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhA1giYsmWV9r2yJZYAiMGHJfjLlLeqAuTAokUGPN__pkxg3RjcIJ2X4N1ZHCCIyiFd2FrdTIP",
  ]
  
  # mount discv5
  node.wakuDiscv5 = WakuDiscoveryV5.new(
      some(extIp), some(nodeTcpPort1), some(nodeUdpPort1),
      bindIp,
      nodeUdpPort1,
      bootstrapNodes,
      false,
      keys.PrivateKey(nodeKey1.skkey),
      flags,
      [],
      node.rng
    )

  let d = node.wakuDiscv5.protocol
  d.open()

  while true:
    # discover new random nodes
    let discoveredNodes = await d.queryRandom()

    # nodes are nested into bucket, flat it
    let flatNodes = d.routingTable.buckets.mapIt(it.nodes).flatten()
    
    # populate metrics related to discovered nodes
    setDiscoveredPeersMetrics(discoveredNodes)

    # populate metrics related to capabilities as advertised by the ENR (see waku field)
    setDiscoveredPeersCapabilities(flatNodes)

    # TODO: as this can't scale with thousands of peers,
    # we would need to connect to just newly discovered nodes.
    # tries to connect to all peers in the routing table
    # populate metrics related to peers we could connect
    await setConnectedPeersMetrics(flatNodes, node, conf.timeout)

    let totalNodes = flatNodes.len
    let seenNodes = flatNodes.countIt(it.seen)

    info "discovered nodes: ", total=totalNodes, seen=seenNodes

    # TODO: we dont run ipMajorityLoop
    # TODO: we dont run revalidateLoop to not empty the routing table
    # TODO: connect to nodes to see the protocol they actually support

    # TODO: flag for how aggresive
    await sleepAsync(1000*30)

when isMainModule:
  waitFor main()