import
  std/[tables,times,sequtils],
  stew/byteutils,
  stew/shims/net,
  chronicles,
  chronicles/topics_registry,
  chronos,
  confutils,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  ../../../waku/v2/node/discv5/waku_discv5,
  ../../../waku/v2/node/peer_manager/peer_manager,
  ../../../waku/v2/node/waku_node,
  ../../../waku/v2/protocol/waku_message,
  ../../../waku/v2/utils/time,
  ../../../waku/v2/utils/wakuenr

proc now*(): Timestamp =
  getNanosecondTime(getTime().toUnixFloat())

# An accesible bootstrap node. See wakuv2.prod fleets.status.im
const bootstrapNodes = @["enr:-Nm4QOdTOKZJKTUUZ4O_W932CXIET-M9NamewDnL78P5u9DOGnZlK0JFZ4k0inkfe6iY-0JAaJVovZXc575VV3njeiABgmlkgnY0gmlwhAjS3ueKbXVsdGlhZGRyc7g6ADg2MW5vZGUtMDEuYWMtY24taG9uZ2tvbmctYy53YWt1djIucHJvZC5zdGF0dXNpbS5uZXQGH0DeA4lzZWNwMjU2azGhAo0C-VvfgHiXrxZi3umDiooXMGY9FvYj5_d1Q4EeS7eyg3RjcIJ2X4N1ZHCCIyiFd2FrdTIP"]

# careful if running pub and sub in the same machine
const wakuPort = 60000
const discv5Port = 9000

proc setupAndPublish() {.async.} =
    # use notice to filter all waku messaging
    setLogLevel(LogLevel.NOTICE)
    notice "starting publisher", wakuPort=wakuPort, discv5Port=discv5Port
    let
        nodeKey = crypto.PrivateKey.random(Secp256k1, crypto.newRng()[])[]
        ip = ValidIpAddress.init("0.0.0.0")
        node = WakuNode.new(nodeKey, ip, Port(wakuPort))
        flags = initWakuFlags(lightpush = false, filter = false, store = false, relay = true)

    # assumes behind a firewall, so not care about being discoverable
    node.wakuDiscv5 = WakuDiscoveryV5.new(
        extIp= none(ValidIpAddress),
        extTcpPort = none(Port),
        extUdpPort = none(Port),
        bindIP = ip,
        discv5UdpPort = Port(discv5Port),
        bootstrapNodes = bootstrapNodes,
        privateKey = keys.PrivateKey(nodeKey.skkey),
        flags = flags,
        enrFields = [],
        rng = node.rng)

    await node.start()
    await node.mountRelay()
    if not await node.startDiscv5():
      error "failed to start discv5"
      quit(1)

    # wait for a minimum of peers to be connected, otherwise messages wont be gossiped
    while true:
      let numConnectedPeers = node.peerManager.peerStore[ConnectionBook].book.values().countIt(it == Connected)
      if numConnectedPeers >= 6:
        notice "publisher is ready", connectedPeers=numConnectedPeers, required=6
        break
      notice "waiting to be ready", connectedPeers=numConnectedPeers, required=6
      await sleepAsync(5000)

    # Make sure it matches the publisher. Use default value
    # see spec: https://rfc.vac.dev/spec/23/
    let pubSubTopic = PubsubTopic("/waku/2/default-waku/proto")

    # any content topic can be chosen
    let contentTopic = ContentTopic("/examples/1/pubsub-example/proto")

    notice "publisher service started"
    while true:
      let text = "hi there i'm a publisher"
      let message = WakuMessage(payload: toBytes(text), # content of the message
                                contentTopic: contentTopic,     # content topic to publish to
                                ephemeral: true,                # tell store nodes to not store it
                                timestamp: now())               # current timestamp
      await node.publish(pubSubTopic, message)
      notice "published message", text = text, timestamp = message.timestamp, psTopic = pubSubTopic, contentTopic = contentTopic
      await sleepAsync(5000)

asyncSpawn setupAndPublish()
runForever()
