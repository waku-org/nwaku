import std[net, options, strutils]

type WebSocketSecureConf* {.requiresInit.} = object
  keyPath*: string
  certPath*: string

type WebSocketConf* = object
  port*: Port
  secureConf*: Option[WebSocketSecureConf]

type NetworkConf* = object
  natStrategy*: string # TODO: make enum
  p2pTcpPort*: Port
  dns4DomainName*: Option[string]
  p2pListenAddress*: IpAddress
  extMultiAddrs*: seq[MultiAddress]
  extMultiAddrsOnly*: bool
  webSocketConf*: Option[WebSocketConf]

proc validateNoEmptyStrings(networkConf: NetworkConf): Result[void, string] =
  if networkConf.dns4DomainName.isSome() and
      isEmptyOrWhiteSpace(networkConf.dns4DomainName.get().string):
    return err("dns4DomainName is an empty string, set it to none(string) instead")

    if networkConf.secureConf.isSome() and networkConf.webSocketConf.isSome() and
        networkConf.webSocketConf.secureConf.isSome():
      let secureConf = networkConf.webSocketConf.secureConf.get()
      if isEmptyOrWhiteSpace(secureConf.keyPath):
        return err("websocket.secureConf.keyPath is an empty string")
      if isEmptyOrWhiteSpace(secureConf.certPath):
        return err("websocket.secureConf.certPath is an empty string")

  return ok()

proc validate*(wakuConf: WakuConf): Result[void, string] =
  ?wakuConf.validateNoEmptyStrings()
  return ok()
