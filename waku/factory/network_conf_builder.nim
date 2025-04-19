##############################
## WebSocket Config Builder ##
##############################
type WebSocketConfBuilder* = object
  enabled: Option[bool]
  webSocketPort: Option[Port]
  secureEnabled: Option[bool]
  keyPath: Option[string]
  certPath: Option[string]

proc init*(T: type WebSocketConfBuilder): WebSocketConfBuilder =
  WebSocketConfBuilder()

with(WebSocketConfBuilder, enabled, bool)
with(WebSocketConfBuilder, secureEnabled, bool)
with(WebSocketConfBuilder, webSocketPort, Port)
with(WebSocketConfBuilder, webSocketPort, Port, uint16)
with(WebSocketConfBuilder, keyPath, string)
with(WebSocketConfBuilder, certPath, string)

proc build(b: WebSocketConfBuilder): Result[Option[WebSocketConf], string] =
  if not b.enabled.get(false):
    return ok(none(WebSocketConf))

  if b.webSocketPort.isNone():
    return err("websocket.port is not specified")

  if not b.secureEnabled.get(false):
    return ok(
      some(
        WebSocketConf(
          port: b.websocketPort.get(), secureConf: none(WebSocketSecureConf)
        )
      )
    )

  if b.keyPath.get("") == "":
    return err("WebSocketSecure enabled but key path is not specified")
  if b.certPath.get("") == "":
    return err("WebSocketSecure enabled but cert path is not specified")

  return ok(
    some(
      WebSocketConf(
        port: b.webSocketPort.get(),
        secureConf: some(
          WebSocketSecureConf(keyPath: b.keyPath.get(), certPath: b.certPath.get())
        ),
      )
    )
  )


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
