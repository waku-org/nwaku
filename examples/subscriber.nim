import
  std/[tables, sequtils],
  stew/byteutils,
  stew/shims/net,
  chronicles,
  chronos,
  confutils,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  waku/[
    common/logging,
    node/peer_manager,
    waku_core,
    waku_node,
    waku_enr,
    discovery/waku_discv5,
    factory/builder,
    waku_relay,
  ]

# An accesible bootstrap node. See waku.sandbox fleets.status.im
const bootstrapNode =
  "enr:-QEkuEB3WHNS-xA3RDpfu9A2Qycr3bN3u7VoArMEiDIFZJ6" &
  "6F1EB3d4wxZN1hcdcOX-RfuXB-MQauhJGQbpz3qUofOtLAYJpZI" &
  "J2NIJpcIQI2SVcim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjL" &
  "WNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2" &
  "XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5" &
  "kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQ" &
  "AGAAeJc2VjcDI1NmsxoQPK35Nnz0cWUtSAhBp7zvHEhyU_AqeQU" &
  "lqzLiLxfP2L4oN0Y3CCdl-DdWRwgiMohXdha3UyDw"

# careful if running pub and sub in the same machine
const wakuPort = 50000
const discv5Port = 8000

proc setupAndSubscribe(rng: ref HmacDrbgContext) {.async.} =
  # use notice to filter all waku messaging
  setupLog(logging.LogLevel.NOTICE, logging.LogFormat.TEXT)

  notice "starting subscriber", wakuPort = wakuPort, discv5Port = discv5Port
  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
    ip = parseIpAddress("0.0.0.0")
    flags = CapabilitiesBitfield.init(
      lightpush = false, filter = false, store = false, relay = true
    )

  var enrBuilder = EnrBuilder.init(nodeKey)

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
  builder.withNetworkConfigurationDetails(ip, Port(wakuPort)).tryGet()
  let node = builder.build().tryGet()

  var bootstrapNodeEnr: enr.Record
  discard bootstrapNodeEnr.fromURI(bootstrapNode)

  let discv5Conf = WakuDiscoveryV5Config(
    discv5Config: none(DiscoveryConfig),
    address: ip,
    port: Port(discv5Port),
    privateKey: keys.PrivateKey(nodeKey.skkey),
    bootstrapRecords: @[bootstrapNodeEnr],
    autoupdateRecord: true,
  )

  # assumes behind a firewall, so not care about being discoverable
  let wakuDiscv5 = WakuDiscoveryV5.new(
    node.rng,
    discv5Conf,
    some(node.enr),
    some(node.peerManager),
    node.topicSubscriptionQueue,
  )

  await node.start()
  await node.mountRelay()
  node.peerManager.start()

  (await wakuDiscv5.start()).isOkOr:
    error "failed to start discv5", error = error
    quit(1)

  # wait for a minimum of peers to be connected, otherwise messages wont be gossiped
  while true:
    let numConnectedPeers =
      node.peerManager.peerStore[ConnectionBook].book.values().countIt(it == Connected)
    if numConnectedPeers >= 6:
      notice "subscriber is ready", connectedPeers = numConnectedPeers, required = 6
      break
    notice "waiting to be ready", connectedPeers = numConnectedPeers, required = 6
    await sleepAsync(5000)

  # Make sure it matches the publisher. Use default value
  # see spec: https://rfc.vac.dev/spec/23/
  let pubSubTopic = PubsubTopic("/waku/2/default-waku/proto")

  # any content topic can be chosen. make sure it matches the publisher
  let contentTopic = ContentTopic("/examples/1/pubsub-example/proto")

  proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    let payloadStr = string.fromBytes(msg.payload)
    if msg.contentTopic == contentTopic:
      notice "message received",
        payload = payloadStr,
        pubsubTopic = pubsubTopic,
        contentTopic = msg.contentTopic,
        timestamp = msg.timestamp

  node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(WakuRelayHandler(handler)))

when isMainModule:
  let rng = crypto.newRng()
  asyncSpawn setupAndSubscribe(rng)
  runForever()
