import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys,
  options
  #options as what # TODO: Huh? Redefinition?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

const topicAmount = 100

let node1 = newRpcHttpClient()
let node2 = newRpcHttpClient()
let node3 = newRpcHttpClient()
let node4 = newRpcHttpClient()
let node5 = newRpcHttpClient()
let node6 = newRpcHttpClient()

waitFor node1.connect("localhost", Port(8547))
waitFor node2.connect("localhost", Port(8548))
waitFor node3.connect("localhost", Port(8549))
waitFor node4.connect("localhost", Port(8550))
waitFor node5.connect("localhost", Port(8551))
waitFor node6.connect("localhost", Port(8552))

let version = waitFor node6.wakuVersion()
info "Version is", version

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

# TODO: Implement handler logic
# All subscribing to foobar topic
let res2 = waitFor node2.wakuSubscribe("foobar")
let res3 = waitFor node3.wakuSubscribe("foobar")
let res4 = waitFor node4.wakuSubscribe("foobar")
let res5 = waitFor node5.wakuSubscribe("foobar")
let res6 = waitFor node6.wakuSubscribe("foobar")
os.sleep(2000)

# info "Posting envelopes on all subscribed topics"
for i in 0..<topicAmount:
  let res2 = waitFor node1.wakuPublish("foobar", "hello world")

os.sleep(2000)
