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
import libp2p/nameresolving/dnsresolver
import ../waku_core

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

proc retrieveDynamicBootstrapNodes*(
    dnsDiscovery: bool, dnsDiscoveryUrl: string, dnsDiscoveryNameServers: seq[IpAddress]
): Result[seq[RemotePeerInfo], string] =
  ## Retrieve dynamic bootstrap nodes (DNS discovery)

  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url = dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain = domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers().mapErr(
          proc(e: cstring): string =
            $e
        )
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default
