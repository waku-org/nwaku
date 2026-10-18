{.push raises: [].}

import chronos, results
import
  logos_delivery/kernel/[
    kernel,
    base/peers,
    discovery/peer_exchange,
    protocols/peer_exchange/common,
    protocols/peer_exchange/rpc,
    base/rate_limit/setting,
  ]
import libp2p/multiaddress

proc mountPeerExchange*(
    self: Kernel,
    cluster: Opt[uint16] = Opt.none(uint16),
    rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit,
) {.async: (raises: []).} =
  await self.discovery.mountPeerExchange(cluster, rateLimit)

proc mountPeerExchangeClient*(self: Kernel) {.async: (raises: []).} =
  await self.discovery.mountPeerExchangeClient()

proc fetchPeerExchangePeers*(
    self: Kernel, amount = DefaultPXNumPeersReq
): Future[Result[int, PeerExchangeResponseStatus]] {.async: (raises: []).} =
  return await self.discovery.fetchPeerExchangePeers(amount)

proc startPeerExchangeLoop*(self: Kernel) =
  self.discovery.startPeerExchangeLoop()

proc setPeerExchangePeer*(self: Kernel, peer: RemotePeerInfo | MultiAddress | string) =
  self.discovery.setPeerExchangePeer(peer)
