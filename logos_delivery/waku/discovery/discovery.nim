{.push raises: [].}

import chronos
import
  logos_delivery/waku/[
    waku_core,
    waku_peer_exchange,
    waku_rendezvous/protocol,
    waku_rendezvous/client as rendezvous_client,
    discovery/peer_discovery_interface,
    discovery/waku_kademlia,
    discovery/waku_discv5,
    discovery/discv5_peer_discovery,
    discovery/external_service_discovery,
  ]

type
  Discovery* = object
    ## Peer discovery mechanisms mounted on the node.
    wakuPeerExchange*: WakuPeerExchange
    wakuPeerExchangeClient*: WakuPeerExchangeClient
    wakuRendezvous*: WakuRendezVous
    wakuRendezvousClient*: rendezvous_client.WakuRendezVousClient
    wakuKademlia*: WakuKademlia
    discoveries*: seq[IPeerDiscovery]
      ## Attached IPeerDiscovery backends; started after the node is up,
      ## stopped on node teardown.
    wakuDiscv5*: WakuDiscoveryV5
      ## Set by discv5Discovery on start; kept for direct consumers
      ## (REST builder, ENR/address updates, FFI ops).
    discv5Discovery*: Discv5PeerDiscovery
    externalDiscovery*: ExternalServiceDiscovery
      ## Present when discovery is delegated to an external provider; the
      ## library layer installs its host transport.
    dynamicBootstrapNodes*: seq[RemotePeerInfo]
    dnsRetryLoopHandle*: Future[void]
