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
  ./tester_config,
  ./diagnose_connections,
  ./lpt_metrics

logScope:
  topics = "service peer mgmt"

randomize()

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

## To retrieve peers from PeerExchange partner and return one randomly selected one
## among the ones successfully dialed
## Note: This is kept for future use.
proc selectRandomCapablePeer*(
    pm: PeerManager, codec: string, pubsubTopic: PubsubTopic
): Future[Option[RemotePeerInfo]] {.async.} =
  var cap = Capabilities.Filter
  if codec.contains("lightpush"):
    cap = Capabilities.Lightpush
  elif codec.contains("filter"):
    cap = Capabilities.Filter

  var supportivePeers = pm.wakuPeerStore.getPeersByCapability(cap)

  trace "Found supportive peers count", count = supportivePeers.len()
  trace "Found supportive peers", supportivePeers = $supportivePeers
  if supportivePeers.len == 0:
    return none(RemotePeerInfo)

  var found = none(RemotePeerInfo)
  while found.isNone() and supportivePeers.len > 0:
    let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
    let randomPeer = supportivePeers[rndPeerIndex]

    debug "Dialing random peer",
      idx = $rndPeerIndex, peer = constructMultiaddrStr(randomPeer)

    supportivePeers.delete(rndPeerIndex..rndPeerIndex)

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

# Debugging PX gathered peers connectivity
proc tryCallAllPxPeers*(
    pm: PeerManager, codec: string, pubsubTopic: PubsubTopic
): Future[Option[seq[RemotePeerInfo]]] {.async.} =
  var capability = Capabilities.Filter
  if codec.contains("lightpush"):
    capability = Capabilities.Lightpush
  elif codec.contains("filter"):
    capability = Capabilities.Filter

  var supportivePeers = pm.wakuPeerStore.getPeersByCapability(capability)

  lpt_px_peers.set(supportivePeers.len)
  debug "Found supportive peers count", count = supportivePeers.len()
  debug "Found supportive peers", supportivePeers = $supportivePeers
  if supportivePeers.len == 0:
    return none(seq[RemotePeerInfo])

  var okPeers: seq[RemotePeerInfo] = @[]

  while supportivePeers.len > 0:
    let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
    let randomPeer = supportivePeers[rndPeerIndex]

    debug "Dialing random peer",
      idx = $rndPeerIndex, peer = constructMultiaddrStr(randomPeer)

    supportivePeers.delete(rndPeerIndex, rndPeerIndex)

    let connOpt = pm.dialPeer(randomPeer, codec)
    if (await connOpt.withTimeout(10.seconds)):
      if connOpt.value().isSome():
        okPeers.add(randomPeer)
        info "Dialing successful",
          peer = constructMultiaddrStr(randomPeer), codec = codec
        lpt_dialed_peers.inc()
      else:
        lpt_dial_failures.inc()
        error "Dialing failed", peer = constructMultiaddrStr(randomPeer), codec = codec
    else:
      lpt_dial_failures.inc()
      error "Timeout dialing service peer",
        peer = constructMultiaddrStr(randomPeer), codec = codec

  var okPeersStr: string = ""
  for idx, peer in okPeers:
    okPeersStr.add(
      "    " & $idx & ". | " & constructMultiaddrStr(peer) & " | protos: " &
        $peer.protocols & " | caps: " & $peer.enr.map(getCapabilities) & "\n"
    )
  echo "PX returned peers found callable for " & codec & " / " & $capability & ":\n"
  echo okPeersStr

  return some(okPeers)

proc pxLookupServiceNode*(
    node: WakuNode, conf: LiteProtocolTesterConf
): Future[Result[bool, void]] {.async.} =
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

    let peerOpt = await tryCallAllPxPeers(node.peerManager, codec, conf.pubsubTopics[0])
    if peerOpt.isSome():
      info "Found service peers for codec",
        codec = codec, peer_count = peerOpt.get().len()
      return ok(peerOpt.get().len > 0)

    await sleepAsync(5.seconds)
    trialCount -= 1

  return err()

var alreadyUsedServicePeers {.threadvar.}: seq[RemotePeerInfo]

## Select service peers by codec from peer store randomly.
proc selectRandomServicePeer*(
    pm: PeerManager, actualPeer: Option[RemotePeerInfo], codec: string
): Result[RemotePeerInfo, void] =
  if actualPeer.isSome():
    alreadyUsedServicePeers.add(actualPeer.get())

  let supportivePeers = pm.wakuPeerStore.getPeersByProtocol(codec).filterIt(
      it notin alreadyUsedServicePeers
    )
  if supportivePeers.len == 0:
    return err()

  let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
  return ok(supportivePeers[rndPeerIndex])
