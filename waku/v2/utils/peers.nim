{.push raises: [Defect].}

# Collection of utilities related to Waku peers
import
  std/strutils,
  stew/results,
  libp2p/[errors,
          multiaddress,
          peerid,
          peerinfo]

type
  RemotePeerInfo* = ref object of RootObj
    peerId*: PeerID
    addrs*: seq[MultiAddress]
    protocols*: seq[string]

func `$`*(remotePeerInfo: RemotePeerInfo): string =
  $remotePeerInfo.peerId

proc init*(
  p: typedesc[RemotePeerInfo],
  peerId: PeerID,
  addrs: seq[MultiAddress] = @[],
  protocols: seq[string] = @[]): RemotePeerInfo =

  let remotePeerInfo = RemotePeerInfo(
    peerId: peerId,
    addrs: addrs,
    protocols: protocols)
  
  return remotePeerInfo

proc init*(p: typedesc[RemotePeerInfo],
           peerId: string,
           addrs: seq[MultiAddress] = @[],
           protocols: seq[string] = @[]): RemotePeerInfo
           {.raises: [Defect, ResultError[cstring], LPError].} =
  
  let remotePeerInfo = RemotePeerInfo(
    peerId: PeerID.init(peerId).tryGet(),
    addrs: addrs,
    protocols: protocols)

  return remotePeerInfo

## Check if wire Address is supported
proc validWireAddr*(ma: MultiAddress): bool =
  const
    ValidTransports = mapOr(TCP, WebSockets)
    ValidAddress = mapAnd(ValidTransports, mapEq("p2p"))
  if ValidTransports.match(ma) == true:
    return true
  else:
    return false

## Parses a fully qualified peer multiaddr, in the
## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
proc parseRemotePeerInfo*(address: string): RemotePeerInfo {.raises: [Defect, ValueError, LPError].}=
  let multiAddr = MultiAddress.init(address).tryGet()

  var

    ipPart, tcpPart, p2pPart, wsPart: MultiAddress

  for addrPart in multiAddr.items():
    case addrPart[].protoName()[]
    of "ip4", "ip6":
      ipPart = addrPart.tryGet()
    of "tcp":
      tcpPart = addrPart.tryGet()
    of "p2p":
      p2pPart = addrPart.tryGet()
    of "ws":
      wsPart = addrPart.tryGet()

  # nim-libp2p dialing requires remote peers to be initialised with a peerId and a wire address
  let
    peerIdStr = p2pPart.toString()[].split("/")[^1] 

    wireAddr = ipPart & tcpPart & wsPart
  if (not wireAddr.validWireAddr()):
    raise newException(ValueError, "Invalid node multi-address")

  return RemotePeerInfo.init(peerIdStr, @[wireAddr])

## Converts the local peerInfo to dialable RemotePeerInfo
## Useful for testing or internal connections
proc toRemotePeerInfo*(peerInfo: PeerInfo): RemotePeerInfo =
  RemotePeerInfo.init(peerInfo.peerId,
                      peerInfo.addrs,
                      peerInfo.protocols)
