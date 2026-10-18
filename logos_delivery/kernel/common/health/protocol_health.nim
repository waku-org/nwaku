import results, std/strformat
import logos_delivery/kernel/[common/health/health_status]
type ProtocolName* {.pure.} = enum
  RelayProtocol = "Relay"
  RlnRelayProtocol = "Rln Relay"
  StoreProtocol = "Store"
  FilterProtocol = "Filter"
  LightpushProtocol = "Lightpush"
  LegacyLightpushProtocol = "Legacy Lightpush"
  PeerExchangeProtocol = "Peer Exchange"
  RendezvousProtocol = "Rendezvous"
  MixProtocol = "Mix"
  StoreClientProtocol = "Store Client"
  FilterClientProtocol = "Filter Client"
  LightpushClientProtocol = "Lightpush Client"
  LegacyLightpushClientProtocol = "Legacy Lightpush Client"

const
  RelayProtocols* = {RelayProtocol}
  StoreClientProtocols* = {StoreClientProtocol}
  LightpushClientProtocols* = {LightpushClientProtocol, LegacyLightpushClientProtocol}
  FilterClientProtocols* = {FilterClientProtocol}

type ProtocolHealth* = object
  protocol*: string
  health*: HealthStatus
  desc*: Opt[string] ## describes why a certain protocol is considered `NOT_READY`

proc notReady*(p: var ProtocolHealth, desc: string): ProtocolHealth =
  p.health = HealthStatus.NOT_READY
  p.desc = Opt.some(desc)
  return p

proc ready*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.READY
  p.desc = Opt.none(string)
  return p

proc notMounted*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.NOT_MOUNTED
  p.desc = Opt.none(string)
  return p

proc synchronizing*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.SYNCHRONIZING
  p.desc = Opt.none(string)
  return p

proc initializing*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.INITIALIZING
  p.desc = Opt.none(string)
  return p

proc shuttingDown*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.SHUTTING_DOWN
  p.desc = Opt.none(string)
  return p

proc `$`*(p: ProtocolHealth): string =
  let desc = p.desc.get("")
  return fmt"protocol: {p.protocol}, health: {p.health}, description: {desc}"

proc init*(p: typedesc[ProtocolHealth], protocol: ProtocolName): ProtocolHealth =
  return ProtocolHealth(
    protocol: $protocol, health: HealthStatus.NOT_MOUNTED, desc: Opt.none(string)
  )
