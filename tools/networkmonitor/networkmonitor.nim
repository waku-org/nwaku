import
  confutils,
  std/tables,
  chronicles,
  chronicles/topics_registry,
  chronos,
  stew/byteutils,
  stew/shims/net,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/wakunode2,
  eth/keys

type
  NetworkMonitorConf* = object
    logLevel* {.
      desc: "Sets the log level",
      defaultValue: LogLevel.DEBUG,
      name: "log-level",
      abbr: "l" .}: LogLevel

proc main() {.async.} = 
  let conf: NetworkMonitorConf = NetworkMonitorConf.load()
  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  let
    rng = keys.newRng()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
    nodeTcpPort1 = Port(60000)
    nodeUdpPort1 = Port(9000)
    node1 = WakuNode.new(
      nodeKey1,
      bindIp,
      nodeTcpPort1)
    
    flags = initWakuFlags(lightpush = false,
                          filter = false,
                          store = false,
                          relay = true)
  
  # waku prod bootstrap nodes
  const bootstrapNodes = @[
    "enr:-JK4QPZWoojZJFRRxV87plIci5aaZMKaTs2YvvmCP7e0TGZPIxKWlkVExJc7xtdjUFw-SRj69FTul25o2uY2akaKpEcBgmlkgnY0gmlwhAjS3ueJc2VjcDI1NmsxoQKNAvlb34B4l68WYt7pg4qKFzBmPRb2I-f3dUOBHku3soN0Y3CCdl-DdWRwgiMohXdha3UyDw",
    "enr:-JK4QIJuHZHTCaUOOwupvl7e3K1DyeDI6a609YJKdlovKj0pQa66P-2lMCw5oYUD-veYl0NNLW2CYHLYrC9CmZqDTLEBgmlkgnY0gmlwhLymh5GJc2VjcDI1NmsxoQNuXVf_MkjDcQAka2YcxWfhnbGGlKhRo_kSWwcoK_uGVYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
    "enr:-JK4QOgn2QQHSJCaLUZuxghlFL92VgL2eEd8LOyiYF0jyEkQUlH1KoOnPdcrO39qggSOsWECPWrO8GewdZmKhlvnHhQBgmlkgnY0gmlwhCJ5ZGyJc2VjcDI1NmsxoQP99JB4EKn12UYqGuCf7uWrIF0yeYsP_MN5RCAh-Exbv4N0Y3CCdl-DdWRwgiMohXdha3UyDw",
  ]
  
  # mount discv5
  node1.wakuDiscv5 = WakuDiscoveryV5.new(
      some(extIp), some(nodeTcpPort1), some(nodeUdpPort1),
      bindIp,
      nodeUdpPort1,
      bootstrapNodes,
      false,
      keys.PrivateKey(nodeKey1.skkey),
      flags,
      [], # Empty enr fields, for now
      node1.rng
    )
  await node1.mountRelay()
  await allFutures([node1.start()])
  await allFutures([node1.startDiscv5()])

  while true:
    let discoveredPeers = await node1.wakuDiscv5.findRandomPeers()
    echo node1.wakuDiscv5.protocol.nodesDiscovered
    for bucket in node1.wakuDiscv5.protocol.routingTable.buckets:
      for node in bucket.nodes:
        echo "id", node.id
        echo "pubkey", node.pubkey
        echo "address", node.address
        echo "seen", node.seen
        echo "record", node.record
    await sleepAsync(5000)

when isMainModule:
  waitFor main()