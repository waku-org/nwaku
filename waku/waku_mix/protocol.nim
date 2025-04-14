{.push raises: [].}

import chronicles, std/[options, sequtils], chronos, results, metrics

import
  libp2p/crypto/curve25519,
  mix/mix_protocol,
  mix/mix_node,
  mix/mix_metrics,
  mix/tag_manager,
  libp2p/[multiaddress, multicodec, peerid]

import
  ../node/peer_manager,
  ../waku_core,
  ../waku_enr/mix,
  ../waku_enr,
  ../node/peer_manager/waku_peer_store,
  ../common/nimchronos

logScope:
  topics = "waku mix"

type
  WakuMix* = ref object of MixProtocol
    peerManager*: PeerManager
    clusterId: uint16

  WakuMixResult*[T] = Result[T, string]

proc mixPoolFilter*(cluster: Option[uint16], peer: RemotePeerInfo): bool =
  # Note that origin based(discv5) filtering is not done intentionally
  # so that more mix nodes can be discovered.
  if peer.enr.isNone():
    trace "peer has no ENR", peer = $peer
    return false

  if cluster.isSome() and peer.enr.get().isClusterMismatched(cluster.get()):
    debug "peer has mismatching cluster", peer = $peer
    return false

  # Filter if mix is enabled
  if not peer.enr.get().supportsCapability(Capabilities.Mix):
    debug "peer doesn't support mix", peer = $peer
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

proc populateMixNodePool*(mix: WakuMix) {.async.} =
  # populate only peers that i) are reachable ii) share cluster iii) support mix
  let remotePeers = mix.peerManager.switch.peerStore.getReachablePeers().filterIt(
      mixPoolFilter(some(mix.clusterId), it)
    )
  var mixNodes = initTable[PeerId, MixPubInfo]()

  for i in 0 ..< min(remotePeers.len, 100):
    let remotePeerENR = remotePeers[i].enr.get()
    # TODO: use the most exposed/external multiaddr of the peer, right now using the first
    let maddrWithPeerId =
      toString(appendPeerIdToMultiaddr(remotePeers[i].addrs[0], remotePeers[i].peerId))
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
  return

proc startMixNodePoolMgr*(mix: WakuMix) {.async.} =
  info "starting mix node pool manager"
  # try more aggressively to populate the pool at startup
  var attempts = 50
  # TODO: make initial pool size configurable
  while mix.getNodePoolSize() < 100 and attempts > 0:
    attempts -= 1
    discard mix.populateMixNodePool()
    await sleepAsync(1.seconds)

  # TODO: make interval configurable
  heartbeat "Updating mix node pool", 5.seconds:
    discard mix.populateMixNodePool()

#[ proc getBootStrapMixNodes*(node: WakuNode): Table[PeerId, MixPubInfo] =
  var mixNodes = initTable[PeerId, MixPubInfo]()
  # MixNode Multiaddrs and PublicKeys:
  let bootNodesMultiaddrs = ["/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o",
                             "/ip4/127.0.0.1/tcp/60002/p2p/16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF",
                             "/ip4/127.0.0.1/tcp/60003/p2p/16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA",
                             "/ip4/127.0.0.1/tcp/60004/p2p/16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f",
                             "/ip4/127.0.0.1/tcp/60005/p2p/16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu",
                             ]
  let bootNodesMixPubKeys = ["9d09ce624f76e8f606265edb9cca2b7de9b41772a6d784bddaf92ffa8fba7d2c",
                             "9231e86da6432502900a84f867004ce78632ab52cd8e30b1ec322cd795710c2a",
                             "275cd6889e1f29ca48e5b9edb800d1a94f49f13d393a0ecf1a07af753506de6c",
                             "e0ed594a8d506681be075e8e23723478388fb182477f7a469309a25e7076fc18",
                             "8fd7a1a7c19b403d231452a9b1ea40eb1cc76f455d918ef8980e7685f9eeeb1f"
                             ]
  for index, mixNodeMultiaddr in bootNodesMultiaddrs:
    let peerIdRes = getPeerIdFromMultiAddr(mixNodeMultiaddr)
    if peerIdRes.isErr:
       error "Failed to get peer id from multiaddress: " , error = peerIdRes.error
    let peerId = peerIdRes.get()
    #if (not peerID == nil) and peerID == exceptPeerID:
    #  continue
    let mixNodePubInfo = createMixPubInfo(mixNodeMultiaddr, intoCurve25519Key(ncrutils.fromHex(bootNodesMixPubKeys[index])))

    mixNodes[peerId] = mixNodePubInfo
  info "using mix bootstrap nodes ", bootNodes = mixNodes
  return mixNodes
 ]#

proc new*(
    T: type WakuMix,
    nodeAddr: string,
    switch: Switch,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  info "mixPrivKey", mixPrivKey = mixPrivKey, mixPubKey = mixPubKey

  let localMixNodeInfo = initMixNodeInfo(
    nodeAddr, mixPubKey, mixPrivKey, switch.peerInfo.publicKey.skkey,
    switch.peerInfo.privateKey.skkey,
  )

  # TODO : ideally mix should not be marked ready until certain min pool of mixNodes are discovered
  var m = WakuMix(peerManager: peermgr, clusterId: clusterId)
  m.init(localMixNodeInfo, switch, initTable[PeerId, MixPubInfo]())
  procCall MixProtocol(m).init()

  return ok(m)

proc start*(mix: Wakumix) =
  discard mix.startMixNodePoolMgr()

#[ proc setMixBootStrapNodes*(node: WakuNode,){.async}=
  node.mix.setNodePool(node.getBootStrapMixNodes())
 ]#
# Mix Protocol
