import std/json
import chronos, chronicles, results, strutils, libp2p/multiaddress, ffi
import
  ../../../waku/factory/waku,
  ../../../waku/discovery/waku_dnsdisc,
  ../../../waku/discovery/waku_discv5,
  ../../../waku/waku_core/peers,
  ../../../waku/node/waku_node

proc retrieveBootstrapNodes(
    enrTreeUrl: string, ipDnsServer: string
): Future[Result[seq[string], string]] {.async.} =
  let dnsNameServers = @[parseIpAddress(ipDnsServer)]
  let discoveredPeers: seq[RemotePeerInfo] = (
    await retrieveDynamicBootstrapNodes(enrTreeUrl, dnsNameServers)
  ).valueOr:
    return err("failed discovering peers from DNS: " & $error)

  var multiAddresses = newSeq[string]()

  for discPeer in discoveredPeers:
    for address in discPeer.addrs:
      multiAddresses.add($address & "/p2p/" & $discPeer)

  return ok(multiAddresses)

proc updateDiscv5BootstrapNodes(nodes: string, waku: ptr Waku): Result[void, string] =
  waku.wakuDiscv5.updateBootstrapRecords(nodes).isOkOr:
    return err("error in updateDiscv5BootstrapNodes: " & $error)
  return ok()

proc performPeerExchangeRequestTo(
    numPeers: uint64, waku: ptr Waku
): Future[Result[int, string]] {.async.} =
  let numPeersRecv = (await waku.node.fetchPeerExchangePeers(numPeers)).valueOr:
    return err($error)
  return ok(numPeersRecv)

registerReqFFI(UpdateDiscv5BootNodesReq, waku: ptr Waku):
  proc(bootnodes: cstring): Future[Result[string, string]] {.async.} =
    updateDiscv5BootstrapNodes($bootnodes, waku).isOkOr:
      error "UPDATE_DISCV5_BOOTSTRAP_NODES failed", error = error
      return err($error)

    return ok("discovery request processed correctly")

registerReqFFI(GetBootstrapnodesReq, waku: ptr Waku):
  proc(
      enrTreeUrl: cstring, nameDnsServer: cstring, timeoutMs: cint
  ): Future[Result[string, string]] {.async.} =
    let nodes = (await retrieveBootstrapNodes($enrTreeUrl, $nameDnsServer)).valueOr:
      error "GET_BOOTSTRAP_NODES failed", error = error
      return err($error)

    ## returns a comma-separated string of bootstrap nodes' multiaddresses
    return ok(nodes.join(","))

registerReqFFI(StartDiscv5Req, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    (await waku.wakuDiscv5.start()).isOkOr:
      error "START_DISCV5 failed", error = error
      return err("error starting discv5: " & $error)

    return ok("discv5 started correctly")

registerReqFFI(StopDiscv5Req, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    await waku.wakuDiscv5.stop()
    return ok("discv5 stopped correctly")

registerReqFFI(PeerExchangeReq, waku: ptr Waku):
  proc(numPeers: uint64): Future[Result[string, string]] {.async.} =
    let numValidPeers = (await performPeerExchangeRequestTo(numPeers, waku)).valueOr:
      error "PEER_EXCHANGE failed", error = error
      return err("failed peer exchange: " & $error)

    return ok($numValidPeers)
