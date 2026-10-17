{.push raises: [].}

import chronos, results
import
  logos_delivery/kernel/kernel,
  logos_delivery/kernel/core/peers,
  logos_delivery/kernel/discovery/peer_exchange,
  logos_delivery/kernel/protocols/peer_exchange/[common, rpc],
  logos_delivery/kernel/common/rate_limit/setting

import libp2p/multiaddress

proc mountPeerExchange*(
    node: Kernel,
    cluster: Opt[uint16] = Opt.none(uint16),
    rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit,
) {.async: (raises: []).} =
  await node.discovery.mountPeerExchange(cluster, rateLimit)

proc mountPeerExchangeClient*(node: Kernel) {.async: (raises: []).} =
  await node.discovery.mountPeerExchangeClient()

proc fetchPeerExchangePeers*(
    node: Kernel, amount = DefaultPXNumPeersReq
): Future[Result[int, PeerExchangeResponseStatus]] {.async: (raises: []).} =
  return await node.discovery.fetchPeerExchangePeers(amount)

proc startPeerExchangeLoop*(node: Kernel) =
  node.discovery.startPeerExchangeLoop()

proc setPeerExchangePeer*(node: Kernel, peer: RemotePeerInfo | MultiAddress | string) =
  node.discovery.setPeerExchangePeer(peer)
