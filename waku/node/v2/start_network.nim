import
  strformat, os, osproc, net, confutils, strformat, chronicles, json,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/protocols/protocol,
  libp2p/peerinfo

# Fix ambiguous call error
import strutils except fromHex

const
  defaults ="--log-level:DEBUG --log-metrics --metrics-server --rpc"
  wakuNodeBin = "build" / "wakunode"
  portOffset = 2

type
  NodeInfo* = object
    cmd: string
    master: bool
    address: string
    shift: int
    label: string

# TODO: Then, setup a star network

# TODO: Create Node command, something like this:
# "build/wakunode --log-level:DEBUG --log-metrics --metrics-server --rpc  --waku-topic-interest:false --nodekey:e685079b7fa34dd35d3ffb2e40ab970360e94aa7dcc1262d36a8e2320a2c08ce --ports-shift:2 --discovery:off "
# Ok cool so it is config.nim parseCmdArg, then use fromHex
proc initNodeCmd(shift: int, staticNodes: seq[string] = @[], master = false, label: string): NodeInfo =
  let
    key = SkPrivateKey.random()
    hkey = key.getBytes().toHex()
    rkey = SkPrivateKey.init(fromHex(hkey))
    privKey = PrivateKey(scheme: Secp256k1, skkey: rkey)
    #privKey = PrivateKey.random(Secp256k1)
    keys = KeyPair(seckey: privKey, pubkey: privKey.getKey())
    peerInfo = PeerInfo.init(privKey)
    # XXX
    DefaultAddr = "/ip4/127.0.0.1/tcp/55505"
    hostAddress = MultiAddress.init(DefaultAddr)

  peerInfo.addrs.add(hostAddress)
  let id = peerInfo.id

  info "PeerInfo", id = id, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & id

  result.cmd = wakuNodeBin & " " & defaults & " "
  result.cmd &= "--nodekey:" & hkey & " "
  result.cmd &= "--ports-shift:" & $shift & " "
  if staticNodes.len > 0:
    for staticNode in staticNodes:
      result.cmd &= "--staticnode:" & staticNode & " "
  result.shift = shift
  result.label = label
  result.master = master
  result.address = listenStr

  info "Node command created.", cmd=result.cmd, address = result.address

# TODO: Setup diff topology, star, mesh, etc
let masterNode = initNodeCmd(portOffset, @[], "master node")
let otherNode = initNodeCmd(portOFfset + 1, @[masterNode.address], "other node")

echo masterNode
echo "---"
echo otherNode
