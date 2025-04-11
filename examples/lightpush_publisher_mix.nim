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
  info "dest peer address: ", destPeerAddr = destPeerAddr, destPeerId = destPeerId
  info "peer exchange address: ", pxPeerAddr = pxPeerAddr, pxPeerId = pxPeerId
  let pxPeerInfo =
    RemotePeerInfo.init(destPeerId, @[MultiAddress.init(destPeerAddr).get()])
  node.peerManager.addServicePeer(pxPeerInfo, WakuPeerExchangeCodec)

  let pxPeerInfo1 =
    RemotePeerInfo.init(pxPeerId, @[MultiAddress.init(pxPeerAddr).get()])
  node.peerManager.addServicePeer(pxPeerInfo1, WakuPeerExchangeCodec)

  if not conf.withoutMix:
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
  var conn: Connection
  if not conf.withoutMix:
    conn = MixEntryConnection.newConn(
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

  if not conf.withoutMix:
    while node.getMixNodePoolSize() < conf.minMixPoolSize:
      info "waiting for mix nodes to be discovered",
        currentpoolSize = node.getMixNodePoolSize()
      await sleepAsync(1000)
    notice "publisher service started with mix node pool size ",
      currentpoolSize = node.getMixNodePoolSize()

  var i = 0
  while i < conf.numMsgs:
    if conf.withoutMix:
      let connOpt = await node.peerManager.dialPeer(dPeerId, WakuLightPushCodec)
      if connOpt.isNone():
        error "failed to dial peer"
        return
      conn = connOpt.get()
    i = i + 1
    let text =
      """Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam venenatis magna ut tortor faucibus, in vestibulum nibh commodo. Aenean eget vestibulum augue. Nullam suscipit urna non nunc efficitur, at iaculis nisl consequat. Mauris quis ultrices elit. Suspendisse lobortis odio vitae laoreet facilisis. Cras ornare sem felis, at vulputate magna aliquam ac. Duis quis est ultricies, euismod nulla ac, interdum dui. Maecenas sit amet est vitae enim commodo gravida. Proin vitae elit nulla. Donec tempor dolor lectus, in faucibus velit elementum quis. Donec non mauris eu nibh faucibus cursus ut egestas dolor. Aliquam venenatis ligula id velit pulvinar malesuada. Vestibulum scelerisque, justo non porta gravida, nulla justo tempor purus, at sollicitudin erat erat vel libero.
      Fusce nec eros eu metus tristique aliquet. Sed ut magna sagittis, vulputate diam sit amet, aliquam magna. Aenean sollicitudin velit lacus, eu ultrices magna semper at. Integer vitae felis ligula. In a eros nec risus condimentum tincidunt fermentum sit amet ex. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas. Nullam vitae justo maximus, fringilla tellus nec, rutrum purus. Etiam efficitur nisi dapibus euismod vestibulum. Phasellus at felis elementum, tristique nulla ac, consectetur neque.
      Maecenas hendrerit nibh eget velit rutrum, in ornare mauris molestie. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia curae; Praesent dignissim efficitur eros, sit amet rutrum justo mattis a. Fusce mollis neque at erat placerat bibendum. Ut fringilla fringilla orci, ut fringilla metus fermentum vel. In hac habitasse platea dictumst. Donec hendrerit porttitor odio. Suspendisse ornare sollicitudin mauris, sodales pulvinar velit finibus vel. Fusce id pulvinar neque. Suspendisse eget tincidunt sapien, ac accumsan turpis.
      Curabitur cursus tincidunt leo at aliquet. Nunc dapibus quam id venenatis varius. Aenean eget augue vel velit dapibus aliquam. Nulla facilisi. Curabitur cursus, turpis vel congue volutpat, tellus eros cursus lacus, eu fringilla turpis orci non ipsum. In hac habitasse platea dictumst. Nulla aliquam nisl a nunc placerat, eget dignissim felis pulvinar. Fusce sed porta mauris. Donec sodales arcu in nisl sodales, quis posuere massa ultricies. Nam feugiat massa eget felis ultricies finibus. Nunc magna nulla, interdum a elit vel, egestas efficitur urna. Ut posuere tincidunt odio in maximus. Sed at dignissim est.
      Morbi accumsan elementum ligula ut fringilla. Praesent in ex metus. Phasellus urna est, tempus sit amet elementum vitae, sollicitudin vel ipsum. Fusce hendrerit eleifend dignissim. Maecenas tempor dapibus dui quis laoreet. Cras tincidunt sed ipsum sed pellentesque. Proin ut tellus nec ipsum varius interdum. Curabitur id velit ligula. Etiam sapien nulla, cursus sodales orci eu, porta lobortis nunc. Nunc at dapibus velit. Nulla et nunc vehicula, condimentum erat quis, elementum dolor. Quisque eu metus fermentum, vestibulum tellus at, sollicitudin odio. Ut vel neque justo.
      Praesent porta porta velit, vel porttitor sem. Donec sagittis at nulla venenatis iaculis. Nullam vel eleifend felis. Nullam a pellentesque lectus. Aliquam tincidunt semper dui sed bibendum. Donec hendrerit, urna et cursus dictum, neque neque convallis magna, id condimentum sem urna quis massa. Fusce non quam vulputate, fermentum mauris at, malesuada ipsum. Mauris id pellentesque libero. Donec vel erat ullamcorper, dapibus quam id, imperdiet urna. Praesent sed ligula ut est pellentesque pharetra quis et diam. Ut placerat lorem eget mi fermentum aliquet.
      This is message #""" &
      $i & """ sent from a publisher using mix. End of transmission."""
    let message = WakuMessage(
      payload: toBytes(text), # content of the message
      contentTopic: LightpushContentTopic, # content topic to publish to
      ephemeral: true, # tell store nodes to not store it
      timestamp: now(),
    ) # current timestamp

    let res = await node.wakuLightpushClient.publishWithConn(
      LightpushPubsubTopic, message, conn, dPeerId
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

    if conf.withoutMix:
      await conn.close()
    await sleepAsync(conf.msgInterval)
  info "###########Sent all messages via mix"
  quit(0)

when isMainModule:
  let conf = LPMixConf.load()
  let rng = crypto.newRng()
  asyncSpawn setupAndPublish(rng, conf)
  runForever()
