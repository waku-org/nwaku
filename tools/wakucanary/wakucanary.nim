import
  confutils,
  chronos
import
  libp2p/protocols/ping,
  libp2p/crypto/[crypto, secp]
import
  chronicles, stew/shims/net as stewNet, std/os,
  eth/keys
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2

type
  WakuCanaryConf* = object

    staticnode* {.
      desc: "Multiaddress of a static node to attemp to dial",
      defaultValue: ""
      name: "staticnode" }: string

    storenode* {.
      desc: "Multiaddress of a store node to attemp to dial",
      defaultValue: ""
      name: "storenode" }: string

proc main(): Future[int] {.async.} =
  result = 0

  let conf: WakuCanaryConf = WakuCanaryConf.load()

  # TODO: handle store node
  let peer: RemotePeerInfo = parseRemotePeerInfo(conf.staticnode)

  # TODO: allow only one flag staticnode|storenode
  echo(conf.staticnode)
  echo(conf.storenode)

  let
    rng = crypto.newRng()
    nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
    node = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
          Port(60000))

  await node.start()

  # TODO: Make timeout configurable
  await node.connectToNodes(@[peer])

  let lp2pPeerStore = node.switch.peerStore
  let conStatus = node.peerManager.peerStore.connectionBook[peer.peerId]

  if conStatus in [Connected, CanConnect]:
    echo "connected ok to " & $peer.peerId
    # TODO: handle if no protocols exist
    let protocols = lp2pPeerStore[ProtoBook][peer.peerId]
    for protocol in protocols:
      echo protocol
  elif conStatus == CannotConnect:
    echo "could not connect to " & $peer.peerId
    result = 1

let status = waitFor main()
quit status