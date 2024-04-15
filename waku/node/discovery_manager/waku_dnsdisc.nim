when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

## A set of utilities to integrate EIP-1459 DNS-based discovery
## for Waku v2 nodes.
##
## EIP-1459 is defined in https://eips.ethereum.org/EIPS/eip-1459

import
  std/options,
  stew/shims/net,
  chronicles,
  chronos,
  metrics,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/peerid,
  dnsdisc/client
import ../../waku_core

export client

declarePublicGauge waku_dnsdisc_discovered, "number of nodes discovered"
declarePublicGauge waku_dnsdisc_errors, "number of waku dnsdisc errors", ["type"]

logScope:
  topics = "waku dnsdisc"

type WakuDnsDiscovery* = object
  client*: Client
  resolver*: Resolver

#####################
# DNS Discovery API #
#####################

proc emptyResolver*(domain: string): Future[string] {.async, gcsafe.} =
  debug "Empty resolver called", domain = domain
  return ""

proc findPeers*(wdd: var WakuDnsDiscovery): Result[seq[RemotePeerInfo], cstring] =
  ## Find peers to connect to using DNS based discovery

  info "Finding peers using Waku DNS discovery"

  # Synchronise client tree using configured resolver
  var tree: Tree
  try:
    tree = wdd.client.getTree(wdd.resolver)
      # @TODO: this is currently a blocking operation to not violate memory safety
  except Exception:
    error "Failed to synchronise client tree"
    waku_dnsdisc_errors.inc(labelValues = ["tree_sync_failure"])
    return err("Node discovery failed")

  let discoveredEnr = wdd.client.getNodeRecords()

  if discoveredEnr.len > 0:
    info "Successfully discovered ENR", count = discoveredEnr.len
  else:
    trace "No ENR retrieved from client tree"

  var discoveredNodes: seq[RemotePeerInfo]

  for enr in discoveredEnr:
    # Convert discovered ENR to RemotePeerInfo and add to discovered nodes
    let res = enr.toRemotePeerInfo()

    if res.isOk():
      discoveredNodes.add(res.get())
    else:
      error "Failed to convert ENR to peer info", enr = $enr, err = res.error()
      waku_dnsdisc_errors.inc(labelValues = ["peer_info_failure"])

  if discoveredNodes.len > 0:
    info "Successfully discovered nodes", count = discoveredNodes.len
    waku_dnsdisc_discovered.inc(discoveredNodes.len.int64)

  return ok(discoveredNodes)

proc init*(
    T: type WakuDnsDiscovery, locationUrl: string, resolver: Resolver
): Result[T, cstring] =
  ## Initialise Waku peer discovery via DNS

  debug "init WakuDnsDiscovery", locationUrl = locationUrl

  let
    client = ?Client.init(locationUrl)
    wakuDnsDisc = WakuDnsDiscovery(client: client, resolver: resolver)

  debug "init success"

  return ok(wakuDnsDisc)
