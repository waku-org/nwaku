when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, net, sysrand, random, strformat, strutils, sequtils],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto,
  confutils,
  libp2p/wire

import
  waku/[
    factory/external_config,
    common/enr,
    waku_node,
    node/peer_manager,
    waku_lightpush/common,
    waku_relay,
    waku_filter_v2,
    waku_peer_exchange/protocol,
    waku_core/multiaddrstr,
    waku_core/topics/pubsub_topic,
    waku_enr/capabilities,
    waku_enr/sharding,
  ],
  ./tester_config

logScope:
  topics = "service peer mgmt"

proc translateToRemotePeerInfo*(peerAddress: string): Result[RemotePeerInfo, void] =
  var peerInfo: RemotePeerInfo
  var enrRec: enr.Record
  if enrRec.fromURI(peerAddress):
    trace "Parsed ENR", enrRec = $enrRec
    peerInfo = enrRec.toRemotePeerInfo().valueOr:
      error "failed to convert ENR to RemotePeerInfo", error = error
      return err()
  else:
    peerInfo = parsePeerInfo(peerAddress).valueOr:
      error "failed to parse node waku peer-exchange peerId", error = error
      return err()

  return ok(peerInfo)

randomize()

proc selectRandomServicePeer*(
    pm: PeerManager, codec: string, pubsubTopic: PubsubTopic
): Future[Option[RemotePeerInfo]] {.async.} =
  var cap = Capabilities.Filter
  if codec.contains("lightpush"):
    cap = Capabilities.Lightpush
  elif codec.contains("filter"):
    cap = Capabilities.Filter

  var supportivePeers = pm.peerStore.getPeersByCapability(cap)

  debug "Found supportive peers count", count = supportivePeers.len()
  debug "Found supportive peers", supportivePeers = $supportivePeers
  if supportivePeers.len == 0:
    return none(RemotePeerInfo)

  var found = none(RemotePeerInfo)
  while found.isNone() and supportivePeers.len > 0:
    let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
    let randomPeer = supportivePeers[rndPeerIndex]

    debug "Dialing random peer",
      idx = $rndPeerIndex, peer = constructMultiaddrStr(randomPeer)

    supportivePeers.delete(rndPeerIndex, rndPeerIndex)

    let connOpt = pm.dialPeer(randomPeer, codec)
    if (await connOpt.withTimeout(10.seconds)):
      if connOpt.value().isSome():
        found = some(randomPeer)
        debug "Dialing successful",
          peer = constructMultiaddrStr(randomPeer), codec = codec
      else:
        debug "Dialing failed", peer = constructMultiaddrStr(randomPeer), codec = codec
    else:
      debug "Timeout dialing service peer",
        peer = constructMultiaddrStr(randomPeer), codec = codec

  return found

proc pxLookupServiceNode*(
    node: WakuNode, conf: LiteProtocolTesterConf
): Future[Result[RemotePeerInfo, void]] {.async.} =
  var codec: string = WakuLightPushCodec
  if conf.testFunc == TesterFunctionality.RECEIVER:
    codec = WakuFilterSubscribeCodec

  if node.wakuPeerExchange.isNil():
    let peerExchangeNode = translateToRemotePeerInfo(conf.bootstrapNode).valueOr:
      return err()
    info "PeerExchange node", peer = constructMultiaddrStr(peerExchangeNode)
    node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)

    try:
      await node.mountPeerExchange(some(conf.clusterId))
    except CatchableError:
      error "failed to mount waku peer-exchange protocol: ",
        error = getCurrentExceptionMsg()
      return err()

  var trialCount = 5
  while trialCount > 0:
    let futPeers = node.fetchPeerExchangePeers(32)
    if not await futPeers.withTimeout(10.seconds):
      notice "Cannot get peers from PX", round = 5 - trialCount
    else:
      if futPeers.value().isErr():
        info "PeerExchange reported error", error = futPeers.read().error
        return err()

    let peerOpt =
      await selectRandomServicePeer(node.peerManager, codec, conf.pubsubTopics[0])
    if peerOpt.isSome():
      info "Found service peer for codec",
        codec = codec, peer = constructMultiaddrStr(peerOpt.get())
      return ok(peerOpt.get())

    await sleepAsync(5.seconds)
    trialCount -= 1

  return err()

# Debugging PX gathered peers connectivity
proc selectRandomServicePeerWithTestAll*(
    pm: PeerManager, codec: string, pubsubTopic: PubsubTopic
): Future[Option[RemotePeerInfo]] {.async.} =
  var cap = Capabilities.Filter
  if codec.contains("lightpush"):
    cap = Capabilities.Lightpush
  elif codec.contains("filter"):
    cap = Capabilities.Filter

  var supportivePeers = pm.peerStore.getPeersByCapability(cap)
  # .filterIt(
  #     it.enr.isSome() and it.enr.get().containsShard(pubsubTopic)
  #   )

  debug "Found supportive peers count", count = supportivePeers.len()
  debug "Found supportive peers", supportivePeers = $supportivePeers
  if supportivePeers.len == 0:
    return none(RemotePeerInfo)

  var found = none(RemotePeerInfo)
  var okPeers: seq[RemotePeerInfo] = @[]

  while found.isNone() and supportivePeers.len > 0:
    let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
    let randomPeer = supportivePeers[rndPeerIndex]

    debug "Dialing random peer",
      idx = $rndPeerIndex, peer = constructMultiaddrStr(randomPeer)

    supportivePeers.delete(rndPeerIndex, rndPeerIndex)

    let connOpt = pm.dialPeer(randomPeer, codec)
    if (await connOpt.withTimeout(10.seconds)):
      if connOpt.value().isSome():
        okPeers.add(randomPeer)
        debug "Dialing successful",
          peer = constructMultiaddrStr(randomPeer), codec = codec
      else:
        debug "Dialing failed", peer = constructMultiaddrStr(randomPeer), codec = codec
    else:
      debug "Timeout dialing service peer",
        peer = constructMultiaddrStr(randomPeer), codec = codec

  var okPeersStr: string = ""
  for idx, peer in okPeers:
    okPeersStr.add(
      "    " & $idx & ". | " & constructMultiaddrStr(peer) & " | protos: " &
        $peer.protocols & " | caps: " & $peer.enr.map(getCapabilities) & "\n"
    )

  echo okPeersStr

  if okPeers.len > 0:
    found = some(okPeers[rand(0 .. okPeers.len - 1)])

  return found

proc pxLookupServiceNodeSlow*(
    node: WakuNode, conf: LiteProtocolTesterConf
): Future[Result[RemotePeerInfo, void]] {.async.} =
  var codec: string = WakuLightPushCodec
  if conf.testFunc == TesterFunctionality.RECEIVER:
    codec = WakuFilterSubscribeCodec

  if node.wakuPeerExchange.isNil():
    let peerExchangeNode = translateToRemotePeerInfo(conf.bootstrapNode).valueOr:
      return err()
    info "PeerExchange node", peer = constructMultiaddrStr(peerExchangeNode)
    node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)

    try:
      await node.mountPeerExchange(some(conf.clusterId))
    except CatchableError:
      error "failed to mount waku peer-exchange protocol: ",
        error = getCurrentExceptionMsg()
      return err()

  var trialCount = 5
  while trialCount > 0:
    let futPeers = node.fetchPeerExchangePeers(100)
    if not await futPeers.withTimeout(30.seconds):
      notice "Cannot get peers from PX", round = 5 - trialCount
    else:
      if futPeers.value().isErr():
        info "PeerExchange reported error", error = futPeers.read().error
        return err()

    let peerOpt = await selectRandomServicePeerWithTestAll(
      node.peerManager, codec, conf.pubsubTopics[0]
    )
    if peerOpt.isSome():
      info "Found service peer for codec",
        codec = codec, peer = constructMultiaddrStr(peerOpt.get())
      return ok(peerOpt.get())

    await sleepAsync(5.seconds)
    trialCount -= 1

  return err()
