import
  unittest, chronos, strutils,
  eth/[keys, p2p]

var nextPort = 30303

proc localAddress*(port: int): Address =
  let port = Port(port)
  result = Address(udpPort: port, tcpPort: port,
                   ip: parseIpAddress("127.0.0.1"))

proc setupTestNode*(capabilities: varargs[ProtocolInfo, `protocolInfo`]): EthereumNode =
  let keys1 = KeyPair.random()[]
  result = newEthereumNode(keys1, localAddress(nextPort), 1, nil,
                           addAllCapabilities = false)
  nextPort.inc
  for capability in capabilities:
    result.addCapability capability

template asyncTest*(name, body: untyped) =
  test name:
    proc scenario {.async.} = body
    waitFor scenario()

template procSuite*(name, body: untyped) =
  proc suitePayload =
    suite name:
      body

  suitePayload()

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
