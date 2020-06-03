import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys,
  options
  #options as what # TODO: Huh? Redefinition?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

const topicAmount = 100

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

# All full nodes connected etc
#
# let node1 = newRpcHttpClient()
# let node2 = newRpcHttpClient()
# let node3 = newRpcHttpClient()
# let node4 = newRpcHttpClient()
# let node5 = newRpcHttpClient()
# let node6 = newRpcHttpClient()

# waitFor node1.connect("localhost", Port(8547))
# waitFor node2.connect("localhost", Port(8548))
# waitFor node3.connect("localhost", Port(8549))
# waitFor node4.connect("localhost", Port(8550))
# waitFor node5.connect("localhost", Port(8551))
# waitFor node6.connect("localhost", Port(8552))

# let version = waitFor node6.wakuVersion()
# info "Version is", version

# # TODO: Implement handler logic
# # All subscribing to foobar topic
# let res2 = waitFor node2.wakuSubscribe("foobar")
# let res3 = waitFor node3.wakuSubscribe("foobar")
# let res4 = waitFor node4.wakuSubscribe("foobar")
# let res5 = waitFor node5.wakuSubscribe("foobar")
# let res6 = waitFor node6.wakuSubscribe("foobar")
# os.sleep(2000)

# # info "Posting envelopes on all subscribed topics"
# for i in 0..<topicAmount:
#   os.sleep(50)
#   let res2 = waitFor node1.wakuPublish("foobar", "hello world")

# os.sleep(2000)

# for i in 0..<topicAmount:
#   os.sleep(50)
#   let res2 = waitFor node1.wakuPublish("foobar", "hello world2")

let nodea = newRpcHttpClient()
let nodeb = newRpcHttpClient()

waitFor nodea.connect("localhost", Port(8545))
waitFor nodeb.connect("localhost", Port(8546))

let version = waitFor nodea.wakuVersion()
info "Version is", version

# XXX: Unclear if we want nodea to subscribe to own topic or not
let res1 = waitFor nodea.wakuSubscribe("foobar")
let res2 = waitFor nodeb.wakuSubscribe("foobar")


# Node 00 and 05 also subscribe
# XXX I confirm this works. Now to tweak it!
let node0 = newRpcHttpClient()
let node5 = newRpcHttpClient()
waitFor node0.connect("localhost", Port(8547))
waitFor node5.connect("localhost", Port(8552))
let res4 = waitFor node0.wakuSubscribe("foobar")
let res5 = waitFor node5.wakuSubscribe("foobar")

os.sleep(2000)

# XXX: Where is hello world tho?
for i in 0..<topicAmount:
  os.sleep(50)
  var s = "hello " & $2
  var res3 = waitFor nodea.wakuPublish("foobar", s)
