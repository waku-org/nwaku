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
  ../../../waku/common/logging,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_core,
  ../../../waku/waku_node,
  ../../../waku/waku_enr,
  ../../../waku/waku_discv5

# An accesible bootstrap node. See wakuv2.prod fleets.status.im
const bootstrapNode = "enr:-Nm4QOdTOKZJKTUUZ4O_W932CXIET-M9NamewDnL78P5u9DOGnZl" &
                      "K0JFZ4k0inkfe6iY-0JAaJVovZXc575VV3njeiABgmlkgnY0gmlwhAjS" &
                      "3ueKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuYWMtY24taG9uZ2tvbmct" &
                      "Yy53YWt1djIucHJvZC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGh" &
                      "Ao0C-VvfgHiXrxZi3umDiooXMGY9FvYj5_d1Q4EeS7eyg3RjcIJ2X4N1" &
                      "ZHCCIyiFd2FrdTIP"

# careful if running pub and sub in the same machine
const wakuPort = 50000
const discv5Port = 8000

proc setupAndSubscribe(rng: ref HmacDrbgContext) {.async.} =
    # use notice to filter all waku messaging
    setupLogLevel(logging.LogLevel.NOTICE)
    notice "starting subscriber", wakuPort=wakuPort, discv5Port=discv5Port
    let
        nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
        ip = ValidIpAddress.init("0.0.0.0")
        flags = CapabilitiesBitfield.init(lightpush = false, filter = false, store = false, relay = true)

    var builder = WakuNodeBuilder.init()
    builder.withNodeKey(nodeKey)
    builder.withNetworkConfigurationDetails(ip, Port(wakuPort)).tryGet()
    let node = builder.build().tryGet()

    var bootstrapNodeEnr: enr.Record
    discard bootstrapNodeEnr.fromURI(bootstrapNode)

    # assumes behind a firewall, so not care about being discoverable
    let wakuDiscv5 = WakuDiscoveryV5.new(
        extIp= none(ValidIpAddress),
        extTcpPort = none(Port),
        extUdpPort = none(Port),
        bindIP = ip,
        discv5UdpPort = Port(discv5Port),
        bootstrapEnrs = @[bootstrapNodeEnr],
        privateKey = keys.PrivateKey(nodeKey.skkey),
        flags = flags,
        rng = node.rng,
        topics = @[],
        )

    await node.start()
    await node.mountRelay()
    node.peerManager.start()

    let discv5Res = wakuDiscv5.start()
    if discv5Res.isErr():
      error "failed to start discv5", error = discv5Res.error
      quit(1)

    asyncSpawn wakuDiscv5.searchLoop(node.peerManager)

    # wait for a minimum of peers to be connected, otherwise messages wont be gossiped
    while true:
      let numConnectedPeers = node.peerManager.peerStore[ConnectionBook].book.values().countIt(it == Connected)
      if numConnectedPeers >= 6:
        notice "subscriber is ready", connectedPeers=numConnectedPeers, required=6
        break
      notice "waiting to be ready", connectedPeers=numConnectedPeers, required=6
      await sleepAsync(5000)

    # Make sure it matches the publisher. Use default value
    # see spec: https://rfc.vac.dev/spec/23/
    let pubSubTopic = PubsubTopic("/waku/2/default-waku/proto")

    # any content topic can be chosen. make sure it matches the publisher
    let contentTopic = ContentTopic("/examples/1/pubsub-example/proto")

    proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      let payloadStr = string.fromBytes(msg.payload)
      if msg.contentTopic == contentTopic:
        notice "message received", payload=payloadStr,
                                   pubsubTopic=pubsubTopic,
                                   contentTopic=msg.contentTopic,
                                   timestamp=msg.timestamp
    node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(handler))

when isMainModule:
  let rng = crypto.newRng()
  asyncSpawn setupAndSubscribe(rng)
  runForever()
