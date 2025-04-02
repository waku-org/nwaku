import
  std/[tables, times, sequtils, strutils],
  stew/byteutils,
  stew/shims/net,
  chronicles,
  results,
  chronos,
  confutils,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/multiaddress,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  metrics,
  metrics/chronos_httpserver

import mix/entry_connection, mix/protocol, mix/curve25519

import
  waku/[
    common/logging,
    node/peer_manager,
    waku_core,
    waku_core/codecs,
    waku_node,
    waku_enr,
    discovery/waku_discv5,
    factory/builder,
    waku_lightpush/client,
  ],
  ./lightpush_publisher_mix_config,
  ./lightpush_publisher_mix_metrics

proc now*(): Timestamp =
  getNanosecondTime(getTime().toUnixFloat())

const clusterId = 66
const shardId = @[0'u16]

const
  LightpushPubsubTopic = PubsubTopic("/waku/2/rs/66/0")
  LightpushContentTopic = ContentTopic("/examples/1/light-pubsub-mix-example/proto")

proc splitPeerIdAndAddr(maddr: string): (string, string) =
  let parts = maddr.split("/p2p/")
  if parts.len != 2:
    error "Invalid multiaddress format", parts = parts
    return

  let
    address = parts[0]
    peerId = parts[1]
  return (address, peerId)

proc setupAndPublish(rng: ref HmacDrbgContext, conf: LPMixConf) {.async.} =
  # use notice to filter all waku messaging
  setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  notice "starting publisher", wakuPort = conf.port

  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[]).get()
    ip = parseIpAddress("0.0.0.0")
    flags = CapabilitiesBitfield.init(relay = true)

  let relayShards = RelayShards.init(clusterId, shardId).valueOr:
    error "Relay shards initialization failed", error = error
    quit(QuitFailure)

  var enrBuilder = EnrBuilder.init(nodeKey)
  enrBuilder.withWakuRelaySharding(relayShards).expect(
    "Building ENR with relay sharding failed"
  )

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      error "failed to create enr record", error = recordRes.error
      quit(QuitFailure)
    else:
      recordRes.get()
  setLogLevel(logging.LogLevel.TRACE)
  var builder = WakuNodeBuilder.init()
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfigurationDetails(ip, Port(conf.port)).tryGet()

  let node = builder.build().tryGet()

  node.mountMetadata(clusterId).expect("failed to mount waku metadata protocol")
  node.mountLightPushClient()
  try:
    await node.mountPeerExchange(some(uint16(clusterId)))
  except CatchableError:
    error "failed to mount waku peer-exchange protocol: ",
      errmsg = getCurrentExceptionMsg()
    return

  let (destPeerAddr, destPeerId) = splitPeerIdAndAddr(conf.destPeerAddr)
  let (pxPeerAddr, pxPeerId) = splitPeerIdAndAddr(conf.pxAddr)

  let pxPeerInfo =
    RemotePeerInfo.init(destPeerId, @[MultiAddress.init(destPeerAddr).get()])
  node.peerManager.addServicePeer(pxPeerInfo, WakuPeerExchangeCodec)

  let pxPeerInfo1 =
    RemotePeerInfo.init(pxPeerId, @[MultiAddress.init(pxPeerAddr).get()])
  node.peerManager.addServicePeer(pxPeerInfo1, WakuPeerExchangeCodec)

  let keyPairResult = generateKeyPair()
  if keyPairResult.isErr:
    return
  let (mixPrivKey, mixPubKey) = keyPairResult.get()

  (await node.mountMix(mixPrivKey)).isOkOr:
    error "failed to mount waku mix protocol: ", error = $error
    return
  let dPeerId = PeerId.init(destPeerId).valueOr:
    error "Failed to initialize PeerId", err = error
    return

  let conn = MixEntryConnection.newConn(
    destPeerAddr, dPeerId, ProtocolType.fromString(WakuLightPushCodec), node.mix
  )

  await node.start()
  node.peerManager.start()
  node.startPeerExchangeLoop()
  try:
    startMetricsHttpServer("0.0.0.0", Port(8008))
  except Exception:
    error "failed to start metrics server: ", error = getCurrentExceptionMsg()
  (await node.fetchPeerExchangePeers()).isOkOr:
    warn "Cannot fetch peers from peer exchange", cause = error

  while node.getMixNodePoolSize() < conf.minMixPoolSize:
    info "waiting for mix nodes to be discovered",
      currentpoolSize = node.getMixNodePoolSize()
    await sleepAsync(1000)

  notice "publisher service started with mix node pool size ",
    currentpoolSize = node.getMixNodePoolSize()
  var i = 0
  while i < conf.numMsgs:
    i = i + 1
    let text = "hi there i'm a publisher using mix, this is msg number " & $i
    let message = WakuMessage(
      payload: toBytes(text), # content of the message
      contentTopic: LightpushContentTopic, # content topic to publish to
      ephemeral: true, # tell store nodes to not store it
      timestamp: now(),
    ) # current timestamp

    let res = await node.wakuLightpushClient.publishWithConn(
      LightpushPubsubTopic, message, conn
    )

    if res.isOk:
      lp_mix_success.inc()
      notice "published message",
        text = text,
        timestamp = message.timestamp,
        psTopic = LightpushPubsubTopic,
        contentTopic = LightpushContentTopic
    else:
      error "failed to publish message", error = res.error
      lp_mix_failed.inc(labelValues = ["publish_error"])

    await sleepAsync(conf.msgInterval)
  info "###########Sent all messages via mix"
  quit(0)

when isMainModule:
  let conf = LPMixConf.load()
  let rng = crypto.newRng()
  asyncSpawn setupAndPublish(rng, conf)
  runForever()
