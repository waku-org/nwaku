when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strutils, options],
  stew/results,
  chronos,
  chronicles,
  metrics,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  eth/p2p/discoveryv5/node,
  eth/p2p/discoveryv5/protocol
import
  ../utils/peers,
  ./waku_enr

export protocol, waku_enr


declarePublicGauge waku_discv5_discovered, "number of nodes discovered"
declarePublicGauge waku_discv5_errors, "number of waku discv5 errors", ["type"]

logScope:
  topics = "waku discv5"


type
  WakuDiscoveryV5* = ref object
    protocol*: protocol.Protocol
    listening*: bool


####################
# Helper functions #
####################

proc parseBootstrapAddress(address: string): Result[enr.Record, cstring] =
  logScope:
    address = address

  if address[0] == '/':
    return err("MultiAddress bootstrap addresses are not supported")

  let lowerCaseAddress = toLowerAscii(address)
  if lowerCaseAddress.startsWith("enr:"):
    var enrRec: enr.Record
    if not enrRec.fromURI(address):
      return err("Invalid ENR bootstrap record")

    return ok(enrRec)

  elif lowerCaseAddress.startsWith("enode:"):
    return err("ENode bootstrap addresses are not supported")

  else:
    return err("Ignoring unrecognized bootstrap address type")

proc addBootstrapNode*(bootstrapAddr: string,
                       bootstrapEnrs: var seq[enr.Record]) =
  # Ignore empty lines or lines starting with #
  if bootstrapAddr.len == 0 or bootstrapAddr[0] == '#':
    return

  let enrRes = parseBootstrapAddress(bootstrapAddr)
  if enrRes.isOk():
    bootstrapEnrs.add(enrRes.value)
  else:
    warn "Ignoring invalid bootstrap address",
          bootstrapAddr, reason = enrRes.error

proc isWakuNode(node: Node): bool =
  let wakuField = node.record.tryGet(CapabilitiesEnrField, uint8)

  if wakuField.isSome():
    return wakuField.get() != 0x00 # True if any flag set to true

  return false

####################
# Discovery v5 API #
####################

proc findRandomPeers*(wakuDiscv5: WakuDiscoveryV5): Future[Result[seq[RemotePeerInfo], cstring]] {.async.} =
  ## Find random peers to connect to using Discovery v5

  ## Query for a random target and collect all discovered nodes
  let discoveredNodes = await wakuDiscv5.protocol.queryRandom()

  ## Filter based on our needs
  # let filteredNodes = discoveredNodes.filter(isWakuNode) # Currently only a single predicate
  # TODO: consider node filtering based on ENR; we do not filter based on ENR in the first waku discv5 beta stage

  var discoveredPeers: seq[RemotePeerInfo]

  for node in discoveredNodes:
    # Convert discovered ENR to RemotePeerInfo and add to discovered nodes
    let res = node.record.toRemotePeerInfo()

    if res.isOk():
      discoveredPeers.add(res.get())
    else:
      error "Failed to convert ENR to peer info", enr= $node.record, err=res.error
      waku_discv5_errors.inc(labelValues = ["peer_info_failure"])


  return ok(discoveredPeers)

proc new*(T: type WakuDiscoveryV5,
          extIp: Option[ValidIpAddress],
          extTcpPort, extUdpPort: Option[Port],
          bindIP: ValidIpAddress,
          discv5UdpPort: Port,
          bootstrapEnrs = newSeq[enr.Record](),
          enrAutoUpdate = false,
          privateKey: keys.PrivateKey,
          flags: CapabilitiesBitfield,
          multiaddrs = newSeq[MultiAddress](),
          rng: ref HmacDrbgContext,
          discv5Config: protocol.DiscoveryConfig = protocol.defaultDiscoveryConfig): T =
  ## TODO: consider loading from a configurable bootstrap file

  ## We always add the waku field as specified
  var enrInitFields = @[(CapabilitiesEnrField, @[flags.byte])]

  ## Add multiaddresses to ENR
  if multiaddrs.len > 0:
    enrInitFields.add((MULTIADDR_ENR_FIELD, multiaddrs.getRawField()))

  let protocol = newProtocol(
    privateKey,
    enrIp = extIp, enrTcpPort = extTcpPort, enrUdpPort = extUdpPort, # We use the external IP & ports for ENR
    enrInitFields,
    bootstrapEnrs,
    bindPort = discv5UdpPort,
    bindIp = bindIP,
    enrAutoUpdate = enrAutoUpdate,
    config = discv5Config,
    rng = rng)

  return WakuDiscoveryV5(protocol: protocol, listening: false)

# constructor that takes bootstrap Enrs in Enr Uri form
proc new*(T: type WakuDiscoveryV5,
          extIp: Option[ValidIpAddress],
          extTcpPort, extUdpPort: Option[Port],
          bindIP: ValidIpAddress,
          discv5UdpPort: Port,
          bootstrapNodes: seq[string],
          enrAutoUpdate = false,
          privateKey: keys.PrivateKey,
          flags: CapabilitiesBitfield,
          multiaddrs = newSeq[MultiAddress](),
          rng: ref HmacDrbgContext,
          discv5Config: protocol.DiscoveryConfig = protocol.defaultDiscoveryConfig): T =

  var bootstrapEnrs: seq[enr.Record]
  for node in bootstrapNodes:
    addBootstrapNode(node, bootstrapEnrs)

  return WakuDiscoveryV5.new(
        extIP, extTcpPort, extUdpPort,
        bindIP,
        discv5UdpPort,
        bootstrapEnrs,
        enrAutoUpdate,
        privateKey,
        flags,
        multiaddrs,
        rng,
        discv5Config
      )


proc open*(wakuDiscv5: WakuDiscoveryV5) {.raises: [CatchableError].} =
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
