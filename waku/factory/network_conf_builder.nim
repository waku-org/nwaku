##########################
## Network Conf Builder ##
##########################
type NetworkConfBuilder* = object
  dns4DomainName*: Option[string]
  extMultiAddrs*: seq[MultiAddress]
  extMultiAddrsOnly*: Option[bool]
  natStrategy*: Option[string]
  p2pListenAddress*: Option[IpAddress]
  p2pTcpPort*: Option[Port]
  webSocketConf*: Option[WebSocketConf]

proc init*(T: type NetworkConfBuilder): NetworkConfBuilder =
  NetworkConfBuilder(webSocketConf: WebSocketConfBuilder.init())

with(NetworkConfBuilder, dns4DomainName, string)
with(NetworkConfBuilder, extMultiAddrs, seq[MultiAddress])
with(NetworkConfBuilder, extMultiAddrsOnly, bool)
with(NetworkConfBuilder, natStrategy, string)
with(NetworkConfBuilder, p2pListenAddress, IpAddress)
with(NetworkConfBuilder, p2pTcpPort, Port)
with(NetworkConfBuilder, p2pTcpPort, Port, uint16)

proc build(b: NetworkConfBuilder): Result[NetworkConf, string] =
    let webSocketConf = b.webSocketConf.build().valueOr:
        return err("Failed to build websocket conf: " & $error)

  return ok(
    # TODO: improve default handling
      NetworkConf(
        dns4DomainName: b.dns4DomainName,
        extMultiAddrs: b.extMultiAddrs,
        extMultiAddrsOnly: extMultiAddrsOnly.get(false),
        natStrategy: natStrategy.get("any"),
        p2pListenAddress: p2pListenAddress.get(parseIpAddress("0.0.0.0")),
        p2pTcpPort: p2pTcpPort.get(Port(60000)),
        webSocketConf: webSocketConf
    )
  )
