when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import waku_discv5, ../../waku_core

## This module contains the logic needed to discover other peers and
## also to make the "self" node discoverable by other peers.

type DiscoveryManager* = object
  wakuDiscv5*: Option[WakuDiscoveryV5]
  dynamicBootstrapNodes*: seq[RemotePeerInfo]

#[
    TODO: in future PRs we will have:

    WakuNode* = ref object
        peerManager*: PeerManager
        discManager*: DiscoveryManager  <-- we will add this
        ...

    App* = object
        version: string
        conf: WakuNodeConf
        rng: ref HmacDrbgContext
        key: crypto.PrivateKey

        wakuDiscv5: Option[WakuDiscoveryV5]         <-- this will get removed
        dynamicBootstrapNodes: seq[RemotePeerInfo]  <-- this will get removed

        node: WakuNode  <-- this will contain a discManager instance

        restServer: Option[WakuRestServerRef]
        metricsServer: Option[MetricsHttpServerRef]

    ]#
