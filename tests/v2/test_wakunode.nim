import unittest

import confutils, chronicles, chronos, os

import stew/shims/net as stewNet
import libp2p/crypto/crypto
import libp2p/crypto/secp
import eth/keys
import json_rpc/[rpcclient, rpcserver]

import ../../waku/node/v2/[config, wakunode2]

import ../test_helpers

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
