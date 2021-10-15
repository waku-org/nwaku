{.push raises: [Defect].}

import
  std/[strutils, options],
  chronos, chronicles, metrics,
  eth/keys,
  eth/p2p/discoveryv5/[enr, protocol],
  stew/shims/net,
  stew/results,
  ../config,
  ../../utils/peers

export protocol

declarePublicGauge waku_discv5_discovered, "number of nodes discovered"
declarePublicGauge waku_discv5_errors, "number of waku discv5 errors", ["type"]

logScope:
  topics = "wakudiscv5"

type
  WakuDiscoveryV5* = protocol.Protocol

proc parseBootstrapAddress(address: TaintedString):
    Result[enr.Record, cstring] =
  logScope:
    address = string(address)

  if address[0] == '/':
    return err "MultiAddress bootstrap addresses are not supported"
  else:
    let lowerCaseAddress = toLowerAscii(string address)
    if lowerCaseAddress.startsWith("enr:"):
      var enrRec: enr.Record
      if enrRec.fromURI(string address):
        return ok enrRec
      return err "Invalid ENR bootstrap record"
    elif lowerCaseAddress.startsWith("enode:"):
      return err "ENode bootstrap addresses are not supported"
    else:
      return err "Ignoring unrecognized bootstrap address type"

proc addBootstrapNode(bootstrapAddr: string,
                       bootstrapEnrs: var seq[enr.Record]) =
  # Ignore empty lines or lines starting with #
  if bootstrapAddr.len == 0 or bootstrapAddr[0] == '#':
    return

  let enrRes = parseBootstrapAddress(bootstrapAddr)
  if enrRes.isOk:
    bootstrapEnrs.add enrRes.value
  else:
    warn "Ignoring invalid bootstrap address",
          bootstrapAddr, reason = enrRes.error

####################
# Discovery v5 API #
####################

proc findRandomPeers*(wakuDiscv5: WakuDiscoveryV5): Future[Result[seq[RemotePeerInfo], cstring]] {.async.} =
  ## Find random peers to connect to using Discovery v5
  
  ## Query for a random target and collect all discovered nodes
  ## @TODO: we could filter nodes here
  let discoveredNodes = await wakuDiscv5.queryRandom()
  
  var discoveredPeers: seq[RemotePeerInfo]

  for node in discoveredNodes:
    # Convert discovered ENR to RemotePeerInfo and add to discovered nodes
    let res = node.record.toRemotePeerInfo()

    if res.isOk():
      discoveredPeers.add(res.get())
    else:
      error "Failed to convert ENR to peer info", enr=node.record, err=res.error()
      waku_discv5_errors.inc(labelValues = ["peer_info_failure"])

  if discoveredPeers.len > 0:
    info "Successfully discovered nodes", count=discoveredPeers.len
    waku_discv5_discovered.inc(discoveredPeers.len.int64)

  return ok(discoveredPeers)

proc new*(T: type WakuDiscoveryV5,
          config: WakuNodeConf,
          enrIp: Option[ValidIpAddress], enrTcpPort, enrUdpPort: Option[Port],
          privateKey: PrivateKey,
          enrFields: openArray[(string, seq[byte])], rng: ref BrHmacDrbgContext):
          T =
  
  var bootstrapEnrs: seq[enr.Record]
  for node in config.discv5BootstrapNodes:
    addBootstrapNode(node, bootstrapEnrs)
  
  ## TODO: consider loading from a configurable bootstrap file
  
  newProtocol(privateKey, enrIp, enrTcpPort, enrUdpPort, enrFields, bootstrapEnrs,
    bindPort = config.discv5UdpPort,
    bindIp = config.listenAddress,
    enrAutoUpdate = config.discv5EnrAutoUpdate,
    rng = rng)