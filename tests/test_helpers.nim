import
  chronos, bearssl/rand,
  eth/[keys, p2p]

import libp2p/crypto/crypto

var nextPort = 30303

proc localAddress*(port: int): Address =
  let port = Port(port)
  result = Address(udpPort: port, tcpPort: port,
                   ip: parseIpAddress("127.0.0.1"))

proc setupTestNode*(
    rng: ref HmacDrbgContext,
    capabilities: varargs[ProtocolInfo, `protocolInfo`]): EthereumNode =
  let
    keys1 = keys.KeyPair.random(rng[])
    address = localAddress(nextPort)
  result = newEthereumNode(keys1, address, NetworkId(1),
                           addAllCapabilities = false,
                           bindUdpPort = address.udpPort, # Assume same as external
                           bindTcpPort = address.tcpPort, # Assume same as external
                           rng = rng)
  nextPort.inc
  for capability in capabilities:
    result.addCapability capability

# Copied from here: https://github.com/status-im/nim-libp2p/blob/d522537b19a532bc4af94fcd146f779c1f23bad0/tests/helpers.nim#L28
type RngWrap = object
  rng: ref rand.HmacDrbgContext

var rngVar: RngWrap

proc getRng(): ref rand.HmacDrbgContext =
  # TODO if `rngVar` is a threadvar like it should be, there are random and
  #      spurious compile failures on mac - this is not gcsafe but for the
  #      purpose of the tests, it's ok as long as we only use a single thread
  {.gcsafe.}:
    if rngVar.rng.isNil:
      rngVar.rng = crypto.newRng()
    rngVar.rng

template rng*(): ref rand.HmacDrbgContext =
  getRng()
