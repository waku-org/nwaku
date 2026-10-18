## Waku layer API — discovery operations (DNS, discv5, peer exchange).
{.push raises: [].}

import std/[net]
import results, chronos

import logos_delivery/kernel/kernel
import
  logos_delivery/kernel/
    [peer_manager/peers, api/peer_exchange, discovery/dnsdisc, discovery/discv5]

proc dnsDiscovery*(
    self: Kernel, enrTreeUrl: string, nameServer: string, timeoutMs: int
): Future[Result[seq[string], string]] {.async.} =
  try:
    let dnsNameServers = @[parseIpAddress(nameServer)]
    let discoveredPeers = (
      await retrieveDynamicBootstrapNodes(enrTreeUrl, dnsNameServers)
    ).valueOr:
      return err("failed discovering peers from DNS: " & $error)

    var multiAddresses = newSeq[string]()
    for discPeer in discoveredPeers:
      for address in discPeer.addrs:
        multiAddresses.add($address & "/p2p/" & $discPeer)

    return ok(multiAddresses)
  except CatchableError as e:
    return err(e.msg)

proc discv5UpdateBootnodes*(
    self: Kernel, bootnodes: string
): Future[Result[bool, string]] {.async.} =
  ## `bootnodes` is a JSON array of ENRs, e.g. `["enr:...", "enr:..."]`.
  try:
    if self.discovery.discv5.isNil():
      return err("discv5 not started")
    self.discovery.discv5.updateBootstrapRecords(bootnodes).isOkOr:
      return err("error in discv5UpdateBootnodes: " & $error)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc startDiscv5*(self: Kernel): Future[Result[bool, string]] {.async.} =
  try:
    if self.discovery.discv5.isNil():
      return err("discv5 not started")
    (await self.discovery.discv5.start()).isOkOr:
      return err("error starting discv5: " & $error)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc stopDiscv5*(self: Kernel): Future[Result[bool, string]] {.async.} =
  try:
    if self.discovery.discv5.isNil():
      return err("discv5 not started")
    await self.discovery.discv5.stop()
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc peerExchangeRequest*(
    self: Kernel, numPeers: uint64
): Future[Result[int, string]] {.async.} =
  try:
    let numPeersRecv = (await self.fetchPeerExchangePeers(numPeers)).valueOr:
      return err("failed peer exchange: " & $error)
    return ok(numPeersRecv)
  except CatchableError as e:
    return err(e.msg)
