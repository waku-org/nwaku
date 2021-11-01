{.push raises: [Defect].}

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
  discovery/dnsdisc/client,
  ../../utils/peers

export client

declarePublicGauge waku_dnsdisc_discovered, "number of nodes discovered"
declarePublicGauge waku_dnsdisc_errors, "number of waku dnsdisc errors", ["type"]

logScope:
  topics = "wakudnsdisc"

type
  WakuDnsDiscovery* = object
    client*: Client
    resolver*: Resolver

##################
# Util functions #
##################

func createEnr*(privateKey: crypto.PrivateKey,
                enrIp: Option[ValidIpAddress],
                enrTcpPort, enrUdpPort: Option[Port]): enr.Record =
  
  assert privateKey.scheme == PKScheme.Secp256k1

  let
    rawPk = privateKey.getRawBytes().expect("Private key is valid")
    pk = keys.PrivateKey.fromRaw(rawPk).expect("Raw private key is of valid length")
    enr = enr.Record.init(1, pk, enrIp, enrTcpPort, enrUdpPort).expect("Record within size limits")
  
  return enr

#####################
# DNS Discovery API #
#####################

proc emptyResolver*(domain: string): Future[string] {.async, gcsafe.} =
  debug "Empty resolver called", domain=domain
  return ""

proc findPeers*(wdd: var WakuDnsDiscovery): Result[seq[RemotePeerInfo], cstring] =
  ## Find peers to connect to using DNS based discovery
  
  info "Finding peers using Waku DNS discovery"
  
  # Synchronise client tree using configured resolver
  var tree: Tree
  try:
    tree = wdd.client.getTree(wdd.resolver)  # @TODO: this is currently a blocking operation to not violate memory safety
  except Exception:
    error "Failed to synchronise client tree"
    waku_dnsdisc_errors.inc(labelValues = ["tree_sync_failure"])
    return err("Node discovery failed")

  let discoveredEnr = wdd.client.getNodeRecords()

  if discoveredEnr.len > 0:
    info "Successfully discovered ENR", count=discoveredEnr.len
  else:
    trace "No ENR retrieved from client tree"

  var discoveredNodes: seq[RemotePeerInfo]

  for enr in discoveredEnr:
    # Convert discovered ENR to RemotePeerInfo and add to discovered nodes
    let res = enr.toRemotePeerInfo()

    if res.isOk():
      discoveredNodes.add(res.get())
    else:
      error "Failed to convert ENR to peer info", enr=enr, err=res.error()
      waku_dnsdisc_errors.inc(labelValues = ["peer_info_failure"])

  if discoveredNodes.len > 0:
    info "Successfully discovered nodes", count=discoveredNodes.len
    waku_dnsdisc_discovered.inc(discoveredNodes.len.int64)

  return ok(discoveredNodes)

proc init*(T: type WakuDnsDiscovery,
           locationUrl: string,
           resolver: Resolver): Result[T, cstring] =
  ## Initialise Waku peer discovery via DNS
  
  debug "init WakuDnsDiscovery", locationUrl=locationUrl
  
  let
    client = ? Client.init(locationUrl)
    wakuDnsDisc = WakuDnsDiscovery(client: client, resolver: resolver)

  debug "init success"

  return ok(wakuDnsDisc)
