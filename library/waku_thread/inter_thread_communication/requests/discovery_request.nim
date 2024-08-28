import std/[json, sequtils]
import chronos, results, libp2p/multiaddress
import
  ../../../../waku/factory/waku,
  ../../../../waku/discovery/waku_dnsdisc,
  ../../../../waku/discovery/waku_discv5,
  ../../../../waku/waku_core/peers,
  ../../../alloc

type DiscoveryMsgType* = enum
  GET_BOOTSTRAP_NODES
  UPDATE_DISCV5_BOOTSTRAP_NODES
  START_DISCV5
  STOP_DISCV5

type DiscoveryRequest* = object
  operation: DiscoveryMsgType

  ## used in GET_BOOTSTRAP_NODES
  enrTreeUrl: cstring
  nameDnsServer: cstring
  timeoutMs: cint

  ## used in UPDATE_DISCV5_BOOTSTRAP_NODES
  nodes: cstring

proc createShared(
    T: type DiscoveryRequest,
    op: DiscoveryMsgType,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
    nodes: cstring,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].enrTreeUrl = enrTreeUrl.alloc()
  ret[].nameDnsServer = nameDnsServer.alloc()
  ret[].timeoutMs = timeoutMs
  ret[].nodes = nodes.alloc()
  return ret

proc createRetrieveBootstrapNodesRequest*(
    T: type DiscoveryRequest,
    op: DiscoveryMsgType,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
): ptr type T =
  return T.createShared(op, enrTreeUrl, nameDnsServer, timeoutMs, "")

proc createUpdateBootstrapNodesRequest*(
    T: type DiscoveryRequest, op: DiscoveryMsgType, nodes: cstring
): ptr type T =
  return T.createShared(op, "", "", 0, nodes)

proc createDiscV5StartRequest*(T: type DiscoveryRequest): ptr type T =
  return T.createShared(START_DISCV5, "", "", 0, "")

proc createDiscV5StopRequest*(T: type DiscoveryRequest): ptr type T =
  return T.createShared(STOP_DISCV5, "", "", 0, "")

proc destroyShared(self: ptr DiscoveryRequest) =
  deallocShared(self[].enrTreeUrl)
  deallocShared(self[].nameDnsServer)
  deallocShared(self)

proc retrieveBootstrapNodes(
    enrTreeUrl: string, ipDnsServer: string
): Result[seq[string], string] =
  let dnsNameServers = @[parseIpAddress(ipDnsServer)]
  let discoveredPeers: seq[RemotePeerInfo] = retrieveDynamicBootstrapNodes(
    true, enrTreeUrl, dnsNameServers
  ).valueOr:
    return err("failed discovering peers from DNS: " & $error)

  var multiAddresses = newSeq[string]()

  for discPeer in discoveredPeers:
    for address in discPeer.addrs:
      multiAddresses.add($address & "/" & $discPeer)

  return ok(multiAddresses)

proc updateDiscv5BootstrapNodes(nodes: string, waku: ptr Waku): Result[void, string] =
  waku.wakuDiscv5.updateBootstrapRecords(nodes).isOkOr:
    return err("error in updateDiscv5BootstrapNodes: " & $error)
  return ok()

proc process*(
    self: ptr DiscoveryRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of START_DISCV5:
    let res = await waku.wakuDiscv5.start()
    res.isOkOr:
      return err($error)

    return ok("discv5 started correctly")
  of STOP_DISCV5:
    await waku.wakuDiscv5.stop()

    return ok("discv5 stopped correctly")
  of GET_BOOTSTRAP_NODES:
    let nodes = retrieveBootstrapNodes($self[].enrTreeUrl, $self[].nameDnsServer).valueOr:
      return err($error)

    return ok($(%*nodes))
  of UPDATE_DISCV5_BOOTSTRAP_NODES:
    updateDiscv5BootstrapNodes($self[].nodes, waku).isOkOr:
      return err($error)
    return ok("discovery request processed correctly")

  return err("discovery request not handled")
