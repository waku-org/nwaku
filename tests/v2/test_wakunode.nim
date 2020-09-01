{.used.}

import
  std/unittest,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  eth/keys,
  ../../waku/node/v2/[wakunode2, waku_types],
  ../test_helpers

procSuite "WakuNode":
  asyncTest "Message published with content filter is retrievable":
    let
      rng = keys.newRng()
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.init(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))

    await node.start()

    let
      topic = "foo"
      contentTopic = "foobar"
      wakuMessage = WakuMessage(payload: ("hello world").toBytes,
        contentTopic: contentTopic)

    node.publish(topic, wakuMessage)
    # TODO: Add actual subscribe part with receival of message
