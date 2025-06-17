import chronicles, std/[net, options, sequtils], results
import ../waku_conf

logScope:
  topics = "waku conf builder dns discovery"

##################################
## DNS Discovery Config Builder ##
##################################
type DnsDiscoveryConfBuilder* = object
  enabled*: Option[bool]
  enrTreeUrl*: Option[string]
  nameServers*: seq[IpAddress]

proc init*(T: type DnsDiscoveryConfBuilder): DnsDiscoveryConfBuilder =
  DnsDiscoveryConfBuilder()

proc withEnabled*(b: var DnsDiscoveryConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withEnrTreeUrl*(b: var DnsDiscoveryConfBuilder, enrTreeUrl: string) =
  b.enrTreeUrl = some(enrTreeUrl)

proc build*(b: DnsDiscoveryConfBuilder): Result[Option[DnsDiscoveryConf], string] =
  if not b.enabled.get(false):
    return ok(none(DnsDiscoveryConf))

  if b.nameServers.len == 0:
    return err("dnsDiscovery.nameServers is not specified")
  if b.enrTreeUrl.isNone():
    return err("dnsDiscovery.enrTreeUrl is not specified")

  return ok(
    some(DnsDiscoveryConf(nameServers: b.nameServers, enrTreeUrl: b.enrTreeUrl.get()))
  )
