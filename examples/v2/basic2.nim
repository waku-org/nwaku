# Here's an example of how you would start a Waku node, subscribe to topics, and
# publish to them

import confutils, chronicles, chronos, os

import stew/shims/net as stewNet
import libp2p/crypto/crypto
import libp2p/crypto/secp
import eth/keys
import json_rpc/[rpcclient, rpcserver]

import ../../waku/node/v2/config
import ../../waku/node/v2/wakunode2

# Loads the config in `waku/node/v2/config.nim`
let conf = WakuNodeConf.load()

# Node operations happens asynchronously
proc runBackground(conf: WakuNodeConf) {.async.} =
  # Create and start the node
  let node = await WakuNode.init(conf)

  # Subscribe to a topic
  let topic = "foobar"
  proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    info "Hit subscribe handler", topic=topic, data=data, decoded=cast[string](data)
  node.subscribe(topic, handler)

  # Publish to a topic
  let message = cast[seq[byte]]("hello world")
  node.publish(topic, message)

discard runBackground(conf)

runForever()
