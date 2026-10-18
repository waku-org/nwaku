{.used.}

import std/[net, sequtils]
import chronos, results, testutils/unittests
import libp2p/[crypto/crypto, peerinfo, switch]
import libp2p_mix/curve25519
import
  logos_delivery/kernel/[
    kernel,
    subscription_manager,
    api/relay,
    protocols/protocols,
    net/bound_ports,
    api/mix,
    api/kernel_lifecycle,
    protocols/mix/protocol,
    api/publish,
    peer_manager/peer_manager,
    api/lightpush,
    protocols/lightpush/common,
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/message,
    base/peers,
    base/codecs,
    config/conf,
  ],
  ./[wakucore, wakunode, testasync]

type MixSizeNetwork* = object
  nodes*: seq[Kernel]
  infos*: seq[MixNodePubInfo]

proc exit*(net: MixSizeNetwork): Kernel =
  net.nodes[0]

proc meshFormed(net: MixSizeNetwork): bool =
  for node in net.nodes:
    for other in net.nodes:
      if node != other and
          not node.hasMeshPeer(DefaultPubsubTopic, other.peerInfo.peerId):
        return false
  return true

proc startMixNodes*(): Future[MixSizeNetwork] {.async.} =
  ## Starts four connected mix nodes on ephemeral loopback ports.
  var net: MixSizeNetwork
  for i in 0 ..< 4:
    let node = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0), quicEnabled = false
    )
    (await node.mountRelay()).expect("mount relay")
    (await node.mountLightpush()).expect("mount lightpush")
    node.mountMetadata(uint32(DefaultClusterId), @[0'u16]).expect("mount metadata")
    let keys = generateKeyPair().expect("mix keys")
    (await node.mountMix(DefaultClusterId, keys.privateKey, @[])).expect("mount mix")
    (await node.start()).expect("start")
    net.nodes.add(node)
    net.infos.add(
      MixNodePubInfo(
        multiAddr:
          "/ip4/127.0.0.1/tcp/" & $node.boundTcpPort() & "/p2p/" & $node.peerInfo.peerId,
        pubKey: keys.publicKey,
      )
    )
  for i, node in net.nodes:
    node.protocols.mix.addBootNodes(
      (0 ..< net.nodes.len).toSeq().filterIt(it != i).mapIt(net.infos[it])
    )
    proc receive(topic: PubsubTopic, message: WakuMessage) {.async.} =
      discard

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), receive).expect(
      "subscribe"
    )
  for i in 0 ..< net.nodes.len:
    for j in i + 1 ..< net.nodes.len:
      await net.nodes[i].switch.connect(
        net.nodes[j].peerInfo.peerId, net.nodes[j].peerInfo.addrs
      )
  checkUntilTimeout:
    net.meshFormed()
  return net

proc stop*(net: MixSizeNetwork, senders: seq[Kernel]) {.async.} =
  for node in senders:
    (await node.stop()).expect("stop")
  for node in net.nodes:
    (await node.stop()).expect("stop")
