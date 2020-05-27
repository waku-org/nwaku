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

waitFor node1.connect("localhost", Port(8547))
waitFor node2.connect("localhost", Port(8548))

#let version = waitFor node1.wakuVersion()
#info "Version is", version

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

# TODO: Implement handler logic
let res1 = waitFor node2.wakuSubscribe("foobar")
os.sleep(2000)

# info "Posting envelopes on all subscribed topics"
for i in 0..<topicAmount:
  let res2 = waitFor node1.wakuPublish("foobar", "hello world")

os.sleep(2000)
