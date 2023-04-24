when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strutils, options],
  stew/results,
  stew/shims/net,
  chronos,
  chronicles,
  metrics,
  libp2p/multiaddress,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  eth/p2p/discoveryv5/node,
  eth/p2p/discoveryv5/protocol
import
  ./waku_core,
  ./waku_enr

export protocol, waku_enr


declarePublicGauge waku_discv5_discovered, "number of nodes discovered"
declarePublicGauge waku_discv5_errors, "number of waku discv5 errors", ["type"]

logScope:
  topics = "waku discv5"


type WakuDiscoveryV5* = ref object
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
  if enrRes.isErr():
    debug "ignoring invalid bootstrap address", reason = enrRes.error
    return

  bootstrapEnrs.add(enrRes.value)


####################
# Discovery v5 API #
####################

proc new*(T: type WakuDiscoveryV5,
          extIp: Option[ValidIpAddress],
          extTcpPort: Option[Port],
          extUdpPort: Option[Port],
          bindIP: ValidIpAddress,
          discv5UdpPort: Port,
          bootstrapEnrs = newSeq[enr.Record](),
          enrAutoUpdate = false,
          privateKey: keys.PrivateKey,
          flags: CapabilitiesBitfield,
          multiaddrs = newSeq[MultiAddress](),
          rng: ref HmacDrbgContext,
          discv5Config: protocol.DiscoveryConfig = protocol.defaultDiscoveryConfig): T =

  # Add the waku capabilities field
  var enrInitFields = @[(CapabilitiesEnrField, @[flags.byte])]

  # Add the waku multiaddrs field
  if multiaddrs.len > 0:
    let value = waku_enr.encodeMultiaddrs(multiaddrs)
    enrInitFields.add((MultiaddrEnrField, value))

  let protocol = newProtocol(
    privateKey,
    enrIp = extIp,
    enrTcpPort = extTcpPort,
    enrUdpPort = extUdpPort,
    enrInitFields,
    bootstrapEnrs,
    bindPort = discv5UdpPort,
    bindIp = bindIP,
    enrAutoUpdate = enrAutoUpdate,
    config = discv5Config,
    rng = rng
  )

  WakuDiscoveryV5(protocol: protocol, listening: false)

# TODO: Do not raise an exception, return a result
proc open*(wd: WakuDiscoveryV5) {.raises: [CatchableError].} =
  debug "Opening Waku discovery v5 ports"
  if wd.listening:
    return

  wd.protocol.open()
  wd.listening = true

proc start*(wd: WakuDiscoveryV5) =
  debug "starting Waku discovery v5 service"
  wd.protocol.start()

proc closeWait*(wd: WakuDiscoveryV5) {.async.} =
  debug "closing Waku discovery v5 node"
  if not wd.listening:
    return

  wd.listening = false
  await wd.protocol.closeWait()

proc findRandomPeers*(wd: WakuDiscoveryV5): Future[Result[seq[RemotePeerInfo], cstring]] {.async.} =
  ## Find random peers to connect to using Discovery v5

  # Query for a random target and collect all discovered nodes
  let discoveredNodes = await wd.protocol.queryRandom()

  ## Filter based on our needs
  # let filteredNodes = discoveredNodes.filter(isWakuNode) # Currently only a single predicate
  # TODO: consider node filtering based on ENR; we do not filter based on ENR in the first waku discv5 beta stage

  var discoveredPeers: seq[RemotePeerInfo]

  for node in discoveredNodes:
    let res = node.record.toRemotePeerInfo()
    if res.isErr():
      error "failed to convert ENR to peer info", enr= $node.record, err=res.error
      waku_discv5_errors.inc(labelValues = ["peer_info_failure"])
      continue

    discoveredPeers.add(res.value)


  return ok(discoveredPeers)
