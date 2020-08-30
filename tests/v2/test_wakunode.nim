{.used.}

import
  std/[unittest, os],
  confutils, chronicles, chronos, stew/shims/net as stewNet,
  json_rpc/[rpcclient, rpcserver],
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  eth/keys,
  ../../waku/node/v2/[config, wakunode2, waku_types],
  ../test_helpers

procSuite "WakuNode":
  asyncTest "Message published with content filter is retrievable":
    let conf = WakuNodeConf.load()
    let
      rng = keys.newRng()
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.init(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))

    await node.start(conf) # TODO: get rid of conf

    let topic = "foobar"

    let message = cast[seq[byte]]("hello world")
    node.publish(topic, ContentFilter(contentTopic: topic), message)

    let response = node.query(HistoryQuery(topics: @[topic]))
    check:
      response.messages.len == 1
      response.messages[0] == message
