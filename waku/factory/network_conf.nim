import std/[net, options, strutils]
import libp2p/multiaddress

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

    if networkConf.webSocketConf.isSome() and
        networkConf.webSocketConf.get().secureConf.isSome():
      let secureConf = networkConf.webSocketConf.get().secureConf.get()
      if isEmptyOrWhiteSpace(secureConf.keyPath):
        return err("websocket.secureConf.keyPath is an empty string")
      if isEmptyOrWhiteSpace(secureConf.certPath):
        return err("websocket.secureConf.certPath is an empty string")

  return ok()
