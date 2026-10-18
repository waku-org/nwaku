{.push raises: [].}

import
  std/[tables, net],
  chronos,
  chronicles,
  metrics,
  results,
  eth/p2p/discoveryv5/enr,
  libp2p/protocols/ping,
  libp2p/builders

import
  logos_delivery/kernel/discovery/discovery,
  logos_delivery/kernel/protocols/peer_exchange/[protocol, rpc, common, client],
  logos_delivery/kernel/peer_manager/peers,
  logos_delivery/kernel/protocols/codecs,
  logos_delivery/kernel/peer_manager/peer_manager,
  logos_delivery/kernel/common/rate_limit/setting

declarePublicGauge logos_delivery_px_peers,
  "number of peers (in the node's peerManager) supporting the peer exchange protocol"

logScope:
  topics = "waku node peerexchange api"

## Waku peer-exchange

proc mountPeerExchange*(
    self: Discovery,
    cluster: Opt[uint16] = Opt.none(uint16),
    rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit,
) {.async: (raises: []).} =
  info "mounting waku peer exchange"

  self.peerExchange =
    WakuPeerExchange.new(self.peerManager, cluster, Opt.some(rateLimit))

  if self.isStarted():
    try:
      await self.peerExchange.start()
    except CatchableError:
      error "failed to start wakuPeerExchange", error = getCurrentExceptionMsg()

  try:
    self.switch.mount(self.peerExchange, protocolMatcher(WakuPeerExchangeCodec))
  except LPError:
    error "failed to mount wakuPeerExchange", error = getCurrentExceptionMsg()

proc mountPeerExchangeClient*(self: Discovery) {.async: (raises: []).} =
  info "mounting waku peer exchange client"
  if self.peerExchangeClient.isNil():
    self.peerExchangeClient = WakuPeerExchangeClient.new(self.peerManager)

proc fetchPeerExchangePeers*(
    self: Discovery, amount = DefaultPXNumPeersReq
): Future[Result[int, PeerExchangeResponseStatus]] {.async: (raises: []).} =
  if self.peerExchangeClient.isNil():
    debug "Could not get peers from px, waku peer-exchange-client is nil"
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        status_desc: Opt.some("PeerExchangeClient is not mounted"),
      )
    )

  debug "Retrieving peer info via peer exchange protocol", amount
  let pxPeersRes = await self.peerExchangeClient.request(amount)
  if pxPeersRes.isOk():
    var validPeers = 0
    let peers = pxPeersRes.get().peerInfos
    for pi in peers:
      var record: enr.Record
      if enr.fromBytes(record, pi.enr):
        # A record without a dialable endpoint is legal, and nothing to dial.
        let peerInfo = record.toRemotePeerInfo().valueOr:
          debug "Skipping peer exchange record", error = error
          continue
        self.peerManager.addPeer(peerInfo, PeerExchange)
        validPeers += 1
    debug "Retrieved peer info via peer exchange protocol",
      validPeers = validPeers, totalPeers = peers.len
    return ok(validPeers)
  else:
    debug "Failed to retrieve peer info via peer exchange protocol",
      error = pxPeersRes.error
    return err(pxPeersRes.error)

proc peerExchangeLoop(self: Discovery) {.async.} =
  while true:
    if not self.isStarted():
      await sleepAsync(5.seconds)
      continue
    (await self.fetchPeerExchangePeers()).isOkOr:
      debug "Cannot fetch peers from peer exchange", cause = error
    await sleepAsync(1.minutes)

proc startPeerExchangeLoop*(self: Discovery) =
  if self.peerExchangeClient.isNil():
    debug "startPeerExchangeLoop: Peer Exchange is not mounted"
    return
  debug "Starting peer exchange loop"
  self.peerExchangeClient.pxLoopHandle = self.peerExchangeLoop()

# TODO: Move to application module (e.g., logosdeliverynode.nim)
proc setPeerExchangePeer*(
    self: Discovery, peer: RemotePeerInfo | MultiAddress | string
) =
  if self.peerExchange.isNil():
    debug "Could not set peer, waku peer-exchange is nil"
    return

  debug "Set peer-exchange peer", peer = peer

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Could not parse peer info", error = error
    return

  self.peerManager.addPeer(remotePeer, PeerExchange)
  logos_delivery_px_peers.inc()
