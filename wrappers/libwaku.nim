## libwaku
##
## Exposes a C API that can be used by other environment than C.

import
  std/[options, tables, strutils, sequtils],
  chronos, chronicles, metrics,
  confutils, json_rpc/rpcserver,

  stew/shims/net as stewNet,
  eth/keys,
  libp2p/multiaddress,
  libp2p/crypto/crypto,

  ../waku/v2/node/wakunode2,
  ../waku/v2/node/config,
  ../waku/v2/node/jsonrpc/[admin_api,
                           debug_api,
                           filter_api,
                           private_api,
                           relay_api,
                           store_api],
  ../waku/common/utils/nat


# TODO Start a node
# TODO Mock info call
# TODO Write header file
# TODO Write example C code file
# TODO Wrap info call
# TODO Init a node

# proc info*(node: WakuNode): WakuInfo =
proc info(foo: cstring): cstring {.exportc, dynlib.} =
  echo "info about node"
  echo foo
  return foo

# XXX Async seems tricky with C here
proc nwaku_start(): bool {.exportc, dynlib.} =
  echo "Start WakuNode"

  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodekey, conf.listenAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  discard node.start()
  return true


proc echo() {.exportc.} =
 echo "echo"

# TODO Here at the moment, start the node
# Then do info call
# WIP
#proc main() {.async.} =
#  let
#    rng = crypto.newRng()
#    conf = WakuNodeConf.load()
#    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
#      Port(uint16(conf.tcpPort) + conf.portsShift),
#      Port(uint16(conf.udpPort) + conf.portsShift))
#    node = WakuNode.init(conf.nodeKey, conf.listenAddress,
#      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)
#
#  await node.start()
#
#main()

  # When main done stuff


echo "hello there"
var foo = nwaku_start()
runForever()
