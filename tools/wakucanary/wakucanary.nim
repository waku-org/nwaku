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

  let conf: WakuCanaryConf = WakuCanaryConf.load()

  # TODO: handle store node
  let peer: RemotePeerInfo = parseRemotePeerInfo(conf.staticnode)

  echo(conf.staticnode)
  echo(conf.storenode)

  let
    rng = crypto.newRng()
    nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
    node = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
          Port(60000))

  await node.start()

  await node.mountLibp2pPing()

  for i in 1..10:
    echo "attempt: " & $i
    await node.connectToNodes(@[peer])
    os.sleep(2000)
  
  # TODO:
  return 1

echo waitFor main()

