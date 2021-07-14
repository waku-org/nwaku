{.push raises: [Defect].}

# Collection of utilities related to Waku peers
import
  std/strutils,
  libp2p/multiaddress,
  libp2p/peerinfo

proc initAddress(T: type MultiAddress, str: string): T {.raises: [Defect, ValueError, LPError].}=
  # @TODO: Rather than raising exceptions, this should return a Result
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(ValueError,
                       "Invalid bootstrap node multi-address")

## Parses a fully qualified peer multiaddr, in the
## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
proc parsePeerInfo*(address: string): PeerInfo {.raises: [Defect, ValueError, LPError].}=
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
  
  return PeerInfo.init(peerIdStr, [wireAddr])