## Here's a basic example of how you would start a Waku node, subscribe to
## topics, and publish to them.

import
  std/[os,options],
  confutils, chronicles, chronos,
  stew/shims/net as stewNet,
  libp2p/crypto/[crypto,secp],
  eth/keys,
  json_rpc/[rpcclient, rpcserver],
  ../../waku/v2/node/[config, wakunode2],
  ../../waku/common/utils/nat,
  ../../waku/v2/protocol/waku_message

# Node operations happens asynchronously
proc runBackground() {.async.} =
  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.listenAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  await node.start()
  node.mountRelay(rlnRelayEnabled = conf.rlnrelay)

  # Subscribe to a topic
  let topic = cast[Topic]("foobar")
  proc handler(topic: Topic, data: seq[byte]) {.async, gcsafe.} =
    let message = WakuMessage.init(data).value
    let payload = cast[string](message.payload)
    info "Hit subscribe handler", topic=topic, payload=payload, contentTopic=message.contentTopic
  node.subscribe(topic, handler)

  # Publish to a topic
  let payload = cast[seq[byte]]("hello world")
  let message = WakuMessage(payload: payload, contentTopic: ContentTopic(1))
  await node.publish(topic, message)

# TODO Await with try/except here
discard runBackground()

runForever()
