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
  let node = await init(conf)

  # Subscribe to a topic
  let topic = "foobar"
  proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    info "Hit subscribe handler", topic=topic, data=data
  node.subscribe(topic, handler)

discard runBackground(conf)
runForever()

# TODO Lets start with Nim Node API first

# To do more operations on this node, we can do this in two ways:
# - We can use the Nim Node API, which is currently not exposed
# - We can use JSON RPC

# TODO Subscribe and publish to topic via Node API
# Requires https://github.com/status-im/nim-waku/issues/53

# Here's how to do it with JSON RPC

# Get RPC call signatures in Nim
#from strutils import rsplit
#template sourceDir: string = currentSourcePath.parentDir().parentDir().rsplit(DirSep, 1)[0]
#const sigWakuPath = sourceDir / "waku" / "node" / "v2" / "rpc" / "wakucallsigs.nim"

#createRpcSigs(RpcHttpClient, sigWakuPath)

# Create RPC Client and connect to it
#var node = newRpcHttpClient()
#waitfor node.connect("localhost", Port(8547))

# TODO Do something with res
#var res = waitFor node.wakuSubscribe("apptopic")

# TODO Use publish as well
