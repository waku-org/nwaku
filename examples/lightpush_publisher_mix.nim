import
  std/[tables, times, sequtils],
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
  metrics

import mix/entry_connection, mix/protocol

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
    waku_lightpush/client
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

  let pxPeerInfo = RemotePeerInfo.init(
    conf.destPeerId,
    @[MultiAddress.init(conf.destPeerAddr).get()],
  )
  node.peerManager.addServicePeer(pxPeerInfo, WakuPeerExchangeCodec)

  (
    await node.mountMix(
      intoCurve25519Key(
        ncrutils.fromHex(
          "401dd1eb5582f6dc9488d424aa26ed1092becefcf8543172e6d92c17ed07265a"
        )
      )
    )
  ).isOkOr:
    error "failed to mount waku mix protocol: ", error = $error
    return

  let destPeerId = PeerId.init(conf.destPeerId).valueOr:
    error "Failed to initialize PeerId", err = error
    return

  let conn = MixEntryConnection.newConn(
    conf.destPeerAddr,
    destPeerId,
    ProtocolType.fromString(WakuLightPushCodec),
    node.mix,
  )

  await node.start()
  node.peerManager.start()
  node.startPeerExchangeLoop()

  (await node.fetchPeerExchangePeers()).isOkOr:
    warn "Cannot fetch peers from peer exchange", cause = error

  while node.getMixNodePoolSize() < conf.minMixPoolSize:
    info "waiting for mix nodes to be discovered",
      currentpoolSize = node.getMixNodePoolSize()
    await sleepAsync(1000)

  notice "publisher service started with mix node pool size ", currentpoolSize = node.getMixNodePoolSize()
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

    await sleepAsync(1000)

when isMainModule:
  let conf = LPMixConf.load()
  let rng = crypto.newRng()
  asyncSpawn setupAndPublish(rng, conf)
  runForever()
