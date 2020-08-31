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
    let node = await WakuNode.init(conf)

    let topic = "foobar"

    let message = cast[seq[byte]]("hello world")
    node.publish(topic, ContentFilter(contentTopic: topic), message)

    let response = node.query(HistoryQuery(topics: @[topic]))
    check:
      response.messages.len == 1
      response.messages[0] == message
