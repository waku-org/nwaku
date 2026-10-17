{.push raises: [].}

import chronos
import
  logos_delivery/kernel/[
    core/peers, protocols/peer_exchange/protocol,
    protocols/peer_exchange/client,
    protocols/rendezvous/protocol,
    protocols/rendezvous/client as rendezvous_client,
    discovery/peer_discovery_interface,
    discovery/waku_kademlia,
    discovery/waku_discv5,
    discovery/discv5_peer_discovery,
    discovery/external_service_discovery,
  ]

type Discovery* = ref object ## Peer discovery mechanisms mounted on the node.
  peerExchange*: WakuPeerExchange
  peerExchangeClient*: WakuPeerExchangeClient
  rendezvous*: WakuRendezVous
  rendezvousClient*: rendezvous_client.WakuRendezVousClient
  kademlia*: WakuKademlia
  discoveries*: seq[IPeerDiscovery]
    ## Attached IPeerDiscovery backends; started after the node is up,
    ## stopped on node teardown.
  discv5*: WakuDiscoveryV5
    ## Set by discv5Discovery on start; kept for direct consumers
    ## (REST builder, ENR/address updates, FFI ops).
  discv5Discovery*: Discv5PeerDiscovery
  externalDiscovery*: ExternalServiceDiscovery
    ## Present when discovery is delegated to an external provider; the
    ## library layer installs its host transport.
  dynamicBootstrapNodes*: seq[RemotePeerInfo]
  dnsRetryLoopHandle*: Future[void]
