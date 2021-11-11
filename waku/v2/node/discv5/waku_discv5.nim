{.push raises: [Defect].}

import
  std/[bitops, sequtils, strutils, options],
  chronos, chronicles, metrics,
  eth/keys,
  eth/p2p/discoveryv5/[enr, node, protocol],
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
  ## 8-bit flag field to indicate Waku capabilities.
  ## Only the 4 LSBs are currently defined according
  ## to RFC31 (https://rfc.vac.dev/spec/31/).
  WakuEnrBitfield* = uint8 

  WakuDiscoveryV5* = ref object
    protocol*: protocol.Protocol
    listening*: bool

const
  WAKU_ENR_FIELD* = "waku2"

####################
# Helper functions #
####################

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

proc initWakuFlags*(lightpush, filter, store, relay: bool): WakuEnrBitfield =
  ## Creates an waku2 ENR flag bit field according to RFC 31 (https://rfc.vac.dev/spec/31/)
  var v = 0b0000_0000'u8
  if lightpush: v.setBit(3)
  if filter: v.setBit(2)
  if store: v.setBit(1)
  if relay: v.setBit(0)

  return v.WakuEnrBitfield

proc isWakuNode(node: Node): bool =
  let wakuField = node.record.tryGet(WAKU_ENR_FIELD, uint8)
  
  if wakuField.isSome:
    return wakuField.get().WakuEnrBitfield != 0x00 # True if any flag set to true

  return false

####################
# Discovery v5 API #
####################

proc findRandomPeers*(wakuDiscv5: WakuDiscoveryV5): Future[Result[seq[RemotePeerInfo], cstring]] {.async.} =
  ## Find random peers to connect to using Discovery v5
  
  ## Query for a random target and collect all discovered nodes
  let discoveredNodes = await wakuDiscv5.protocol.queryRandom()
  
  ## Filter based on our needs
  let filteredNodes = discoveredNodes.filter(isWakuNode) # Currently only a single predicate

  var discoveredPeers: seq[RemotePeerInfo]

  for node in filteredNodes:
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
          extIp: Option[ValidIpAddress],
          extTcpPort, extUdpPort: Option[Port],
          bindIP: ValidIpAddress,
          discv5UdpPort: Port,
          bootstrapNodes: seq[string],
          enrAutoUpdate = false,
          privateKey: PrivateKey,
          flags: WakuEnrBitfield,
          enrFields: openArray[(string, seq[byte])],
          rng: ref BrHmacDrbgContext): T =
  
  var bootstrapEnrs: seq[enr.Record]
  for node in bootstrapNodes:
    addBootstrapNode(node, bootstrapEnrs)
  
  ## TODO: consider loading from a configurable bootstrap file
  
  ## We always add the waku field as specified
  var enrInitFields = @[(WAKU_ENR_FIELD, @[flags.byte])]
  enrInitFields.add(enrFields)
  
  let protocol = newProtocol(
    privateKey,
    enrIp = extIp, enrTcpPort = extTcpPort, enrUdpPort = extUdpPort, # We use the external IP & ports for ENR
    enrInitFields,
    bootstrapEnrs,
    bindPort = discv5UdpPort,
    bindIp = bindIP,
    enrAutoUpdate = enrAutoUpdate,
    rng = rng)
  
  return WakuDiscoveryV5(protocol: protocol, listening: false)

proc open*(wakuDiscv5: WakuDiscoveryV5) {.raises: [Defect, CatchableError].} =
  debug "Opening Waku discovery v5 ports"

  wakuDiscv5.protocol.open()
  wakuDiscv5.listening = true

proc start*(wakuDiscv5: WakuDiscoveryV5) =
  debug "Starting Waku discovery v5 service"

  wakuDiscv5.protocol.start()

proc closeWait*(wakuDiscv5: WakuDiscoveryV5) {.async.} =
  debug "Closing Waku discovery v5 node"

  wakuDiscv5.listening = false
  await wakuDiscv5.protocol.closeWait()
