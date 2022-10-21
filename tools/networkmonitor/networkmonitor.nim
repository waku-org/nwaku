# TODO: fix imports
import
  confutils,
  sequtils,
  std/sugar,
  std/tables,
  chronicles,
  chronicles/topics_registry,
  chronos,
  stew/byteutils,
  stew/shims/net,
  metrics,
  metrics/chronos_httpserver,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/utils/wakuenr,
  networkmonitor_metrics,
  networkmonitor_config

logScope:
  topics = "networkmonitor"

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
    
    flags = initWakuFlags(lightpush = false,
                          filter = false,
                          store = false,
                          relay = true)


                        
  # TODO: use other discovery mechanisms
  
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
      [], # Empty enr fields, for now
      node.rng
    )
  #await node.mountRelay()
  #await allFutures([node.start()])

  # TODO remove thi. Note that now it doesnt work with it
  await allFutures([node.startDiscv5()]) 
  let d = node.wakuDiscv5.protocol
  while true:
    # we dont care about the result, everything is updated inside the routingTable
    discard await d.queryRandom()

    for bucket in d.routingTable.buckets:
      for node in bucket.nodes:
        #echo "id", node.id
        #echo "pubkey", node.pubkey
        #echo "address", node.address
        #echo "seen", node.seen
        #echo "pairs", node.record
        for capability in @[Relay, Store, Filter, Lightpush]:
          if node.record.supportsCapability(capability):
            echo "node:", node.address, " supports ", capability
            # TODO: add to prometheus metrics
    
    let totalNodes = d.routingTable.buckets.foldl(a + b.nodes.len, 0)
    let seenNodes = d.routingTable.buckets.foldl(a + b.nodes.filterIt(it.seen == true).len, 0)

    echo "total nodes: ", totalNodes
    echo "seen nodes: ", seenNodes

    # TODO: we dont run ipMajorityLoop
    # TODO: we dont run revalidateLoop to not empty the routing table
    # TODO: connect to nodes to see the protocol they actually support

    # TODO: flag for how aggresive
    await sleepAsync(5000)

when isMainModule:
  waitFor main()