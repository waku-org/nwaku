## Here's a basic example of how you would start a Waku node, subscribe to
## topics, and publish to them.

import
  std/os,
  confutils, chronicles, chronos,
  stew/shims/net as stewNet,
  libp2p/crypto/[crypto,secp],
  eth/keys,
  json_rpc/[rpcclient, rpcserver],
  ../../waku/node/v2/[config, wakunode2, waku_types],
  ../../waku/node/common

# Node operations happens asynchronously
proc runBackground() {.async.} =
  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.libp2pAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  await node.start()

  # Subscribe to a topic
  let topic = "foobar"
  proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    info "Hit subscribe handler", topic=topic, data=data, decoded=cast[string](data)
  node.subscribe(topic, handler)

  # Publish to a topic
  let message = cast[seq[byte]]("hello world")
  node.publish(topic, message)

TODO Await with try/except here
discard runBackground()

runForever()
