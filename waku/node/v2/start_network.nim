import
  strformat, os, osproc, net, strformat, chronicles,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
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

  Topology = enum
    Star,
    FullMesh

# NOTE: Don't distinguish between node types here a la full node, light node etc
proc initNodeCmd(shift: int, staticNodes: seq[string] = @[], master = false, label: string): NodeInfo =
  let
    key = SkPrivateKey.random()[] #assumes ok
    hkey = key.getBytes().toHex()
    rkey = SkPrivateKey.init(fromHex(hkey))[] #assumes ok
    privKey = PrivateKey(scheme: Secp256k1, skkey: rkey)
    #privKey = PrivateKey.random(Secp256k1)
    pubkey = privKey.getKey()[] #assumes ok
    keys = KeyPair(seckey: privKey, pubkey: pubkey)
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

proc starNetwork(amount: int): seq[NodeInfo] =
  let masterNode = initNodeCmd(portOffset, master = true, label = "master node")
  result.add(masterNode)
  for i in 1..<amount:
    result.add(initNodeCmd(portOffset + i, @[masterNode.address], label = "full node"))

proc fullMeshNetwork(amount: int): seq[NodeInfo] =
  debug "amount", amount
  for i in 0..<amount:
    var staticnodes: seq[string]
    for item in result:
      staticnodes.add(item.address)
      result.add(initNodeCmd(portOffset + i, staticnodes, label = "full node"))

when isMainModule:
  # TODO: WakuNetworkConf
  var nodes: seq[NodeInfo]
  let topology = Star
  let amount = 6

  # XXX: For some reason Mesh hangs with multitail
  case topology:
    of Star:
      nodes = starNetwork(amount)
    of FullMesh:
      nodes = fullMeshNetwork(amount)


  var commandStr = "multitail -s 2 -M 0 -x \"Waku Simulation\""
  var count = 0
  var sleepDuration = 0
  for node in nodes:
    #if conf.topology in {Star, DiscoveryBased}:
    sleepDuration = if node.master: 0
                    else: 1
    commandStr &= &" -cT ansi -t 'node #{count} {node.label}' -l 'sleep {sleepDuration}; {node.cmd}; echo [node execution completed]; while true; do sleep 100; done'"

  let errorCode = execCmd(commandStr)
  if errorCode != 0:
    error "launch command failed", command=commandStr
