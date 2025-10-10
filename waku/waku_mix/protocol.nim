{.push raises: [].}

import chronicles, std/[options, tables, sequtils], chronos, results, metrics

import
  libp2p/crypto/curve25519,
  mix/mix_protocol,
  mix/mix_node,
  mix/mix_metrics,
  libp2p/[multiaddress, multicodec, peerid],
  eth/common/keys

import
  ../node/peer_manager,
  ../waku_core,
  ../waku_enr,
  ../node/peer_manager/waku_peer_store,
  ../common/nimchronos

logScope:
  topics = "waku mix"

const mixMixPoolSize = 3

type
  WakuMix* = ref object of MixProtocol
    peerManager*: PeerManager
    clusterId: uint16
    nodePoolLoopHandle: Future[void]
    pubKey*: Curve25519Key

  WakuMixResult*[T] = Result[T, string]

  MixNodePubInfo* = object
    multiAddr*: string
    pubKey*: Curve25519Key

proc mixPoolFilter*(cluster: Option[uint16], peer: RemotePeerInfo): bool =
  # Note that origin based(discv5) filtering is not done intentionally
  # so that more mix nodes can be discovered.
  if peer.enr.isNone():
    trace "peer has no ENR", peer = $peer
    return false

  if cluster.isSome() and peer.enr.get().isClusterMismatched(cluster.get()):
    trace "peer has mismatching cluster", peer = $peer
    return false

  # Filter if mix is enabled
  if not peer.enr.get().supportsCapability(Capabilities.Mix):
    trace "peer doesn't support mix", peer = $peer
    return false

  return true

proc appendPeerIdToMultiaddr*(multiaddr: MultiAddress, peerId: PeerId): MultiAddress =
  if multiaddr.contains(multiCodec("p2p")).get():
    return multiaddr

  var maddrStr = multiaddr.toString().valueOr:
    error "Failed to convert multiaddress to string.", err = error
    return multiaddr
  maddrStr.add("/p2p/" & $peerId)
  var cleanAddr = MultiAddress.init(maddrStr).valueOr:
    error "Failed to convert string to multiaddress.", err = error
    return multiaddr
  return cleanAddr

func getIPv4Multiaddr*(maddrs: seq[MultiAddress]): Option[MultiAddress] =
  for multiaddr in maddrs:
    trace "checking multiaddr", addr = $multiaddr
    if multiaddr.contains(multiCodec("ip4")).get():
      trace "found ipv4 multiaddr", addr = $multiaddr
      return some(multiaddr)
  trace "no ipv4 multiaddr found"
  return none(MultiAddress)

#[ Not deleting as these can be reused once discovery is sorted
  proc populateMixNodePool*(mix: WakuMix) =
  # populate only peers that i) are reachable ii) share cluster iii) support mix
  let remotePeers = mix.peerManager.switch.peerStore.peers().filterIt(
      mixPoolFilter(some(mix.clusterId), it)
    )
  var mixNodes = initTable[PeerId, MixPubInfo]()

  for i in 0 ..< min(remotePeers.len, 100):
    let remotePeerENR = remotePeers[i].enr.get()
    let ipv4addr = getIPv4Multiaddr(remotePeers[i].addrs).valueOr:
      trace "peer has no ipv4 address", peer = $remotePeers[i]
      continue
    let maddrWithPeerId =
      toString(appendPeerIdToMultiaddr(ipv4addr, remotePeers[i].peerId))
    trace "remote peer ENR",
      peerId = remotePeers[i].peerId, enr = remotePeerENR, maddr = maddrWithPeerId

    let peerMixPubKey = mixKey(remotePeerENR).get()
    let mixNodePubInfo =
      createMixPubInfo(maddrWithPeerId.value, intoCurve25519Key(peerMixPubKey))
    mixNodes[remotePeers[i].peerId] = mixNodePubInfo

  mix_pool_size.set(len(mixNodes))
  # set the mix node pool
  mix.setNodePool(mixNodes)
  trace "mix node pool updated", poolSize = mix.getNodePoolSize()

proc startMixNodePoolMgr*(mix: WakuMix) {.async.} =
  info "starting mix node pool manager"
  # try more aggressively to populate the pool at startup
  var attempts = 50
  # TODO: make initial pool size configurable
  while mix.getNodePoolSize() < 100 and attempts > 0:
    attempts -= 1
    mix.populateMixNodePool()
    await sleepAsync(1.seconds)

  # TODO: make interval configurable
  heartbeat "Updating mix node pool", 5.seconds:
    mix.populateMixNodePool()
 ]#
proc toMixNodeTable(bootnodes: seq[MixNodePubInfo]): Table[PeerId, MixPubInfo] =
  var mixNodes = initTable[PeerId, MixPubInfo]()
  for node in bootnodes:
    let peerId = getPeerIdFromMultiAddr(node.multiAddr).valueOr:
      error "Failed to get peer id from multiaddress: ",
        error = error, multiAddr = $node.multiAddr
      continue
    mixNodes[peerId] = createMixPubInfo(node.multiAddr, node.pubKey)
  info "using mix bootstrap nodes ", bootNodes = mixNodes
  return mixNodes

proc new*(
    T: type WakuMix,
    nodeAddr: string,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    bootnodes: seq[MixNodePubInfo],
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  info "mixPrivKey", mixPrivKey = mixPrivKey, mixPubKey = mixPubKey

  let localMixNodeInfo = initMixNodeInfo(
    nodeAddr, mixPubKey, mixPrivKey, peermgr.switch.peerInfo.publicKey.skkey,
    peermgr.switch.peerInfo.privateKey.skkey,
  )
  if bootnodes.len < mixMixPoolSize:
    warn "publishing with mix won't work as there are less than 3 mix nodes in node pool"
  let initTable = toMixNodeTable(bootnodes)
  if len(initTable) < mixMixPoolSize:
    warn "publishing with mix won't work as there are less than 3 mix nodes in node pool"
  var m = WakuMix(peerManager: peermgr, clusterId: clusterId, pubKey: mixPubKey)
  procCall MixProtocol(m).init(localMixNodeInfo, initTable, peermgr.switch)
  return ok(m)

method start*(mix: WakuMix) =
  info "starting waku mix protocol"
  #mix.nodePoolLoopHandle = mix.startMixNodePoolMgr() This can be re-enabled once discovery is addressed

method stop*(mix: WakuMix) {.async.} =
  if mix.nodePoolLoopHandle.isNil():
    return
  await mix.nodePoolLoopHandle.cancelAndWait()
  mix.nodePoolLoopHandle = nil

# Mix Protocol
