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

proc initAddress(T: type MultiAddress, str: string): T {.raises: [Defect, ValueError, LPError].}=
  # @TODO: Rather than raising exceptions, this should return a Result
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    return address
  else:
    raise newException(ValueError,
                       "Invalid bootstrap node multi-address")

## Parses a fully qualified peer multiaddr, in the
## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
proc parseRemotePeerInfo*(address: string): RemotePeerInfo {.raises: [Defect, ValueError, LPError].}=
  let multiAddr = MultiAddress.initAddress(address)

  var
    ipPart, tcpPart, p2pPart: MultiAddress

  for addrPart in multiAddr.items():
    case addrPart[].protoName()[]
    of "ip4", "ip6":
      ipPart = addrPart.tryGet()
    of "tcp":
      tcpPart = addrPart.tryGet()
    of "p2p":
      p2pPart = addrPart.tryGet()
  
  # nim-libp2p dialing requires remote peers to be initialised with a peerId and a wire address
  let
    peerIdStr = p2pPart.toString()[].split("/")[^1]
    wireAddr = ipPart & tcpPart
  
  if (not wireAddr.isWire()):
    raise newException(ValueError, "Invalid node multi-address")
  
  return RemotePeerInfo.init(peerIdStr, @[wireAddr])

## Converts the local peerInfo to dialable RemotePeerInfo
## Useful for testing or internal connections
proc toRemotePeerInfo*(peerInfo: PeerInfo): RemotePeerInfo =
  RemotePeerInfo.init(peerInfo.peerId,
                      peerInfo.addrs,
                      peerInfo.protocols)
