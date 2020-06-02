import
  strformat, os, osproc, net, strformat, chronicles,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerinfo

# Fix ambiguous call error
import strutils except fromHex

const
  defaults ="--log-level:TRACE --log-metrics --metrics-server --rpc"
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
    port = 60000 + shift
    #DefaultAddr = "/ip4/127.0.0.1/tcp/55505"
    address = "/ip4/127.0.0.1/tcp/" & $port
    hostAddress = MultiAddress.init(address).tryGet()

  info "Address", address
  # TODO: Need to port shift
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
  let topology = FullMesh
  let amount = 6

  case topology:
    of Star:
      nodes = starNetwork(amount)
    of FullMesh:
      nodes = fullMeshNetwork(amount)

  var staticnodes: seq[string]
  for i in 0..<amount:
    # TODO: could also select nodes randomly
    staticnodes.add(nodes[i].address)

  # TODO: Here we could add a light node, but not clear thats what we want to test?
  # Lets call them edge nodes
  # NOTE: Only connecting to one node here
  var nodesubseta: seq[string]
  var nodesubsetb: seq[string]
  nodesubseta.add(staticnodes[0])
  nodesubsetb.add(staticnodes[amount-1])
  nodes.add(initNodeCmd(0, nodesubseta, label = "edge node (A)"))
  nodes.add(initNodeCmd(1, nodesubsetb, label = "edge node (B)"))

  var commandStr = "multitail -s 2 -M 0 -x \"Waku Simulation\""
  var count = 0
  var sleepDuration = 0
  for node in nodes:
    if topology in {Star}: #DiscoveryBased
      sleepDuration = if node.master: 0
                      else: 1
    commandStr &= &" -cT ansi -t 'node #{count} {node.label}' -l 'sleep {sleepDuration}; {node.cmd}; echo [node execution completed]; while true; do sleep 100; done'"
    if topology == FullMesh:
      sleepDuration += 1
      count += 1

  let errorCode = execCmd(commandStr)
  if errorCode != 0:
    error "launch command failed", command=commandStr
