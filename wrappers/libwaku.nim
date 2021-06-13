# libwaku
#
# Exposes a C API that can be used by other environment than C.

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
