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

const topicAmount = 10 #100

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

# Scenario xx1 - 16 full nodes
#########################################
let amount = 16
var nodes: seq[RPCHttpClient]
for i in 0..<amount:
  var node = newRpcHttpClient()
  nodes.add(node)
  waitFor nodes[i].connect("localhost", Port(8547+i))
  var res = waitFor nodes[i].wakuSubscribe("waku")

os.sleep(2000)

# # TODO: Show plaintext message in log
# for i in 0..<topicAmount:
#   os.sleep(50)
#   # TODO: This would then publish on a subtopic here
#   var s = "hello " & $2
#   var res3 = waitFor nodes[0].wakuPublish("waku", s)

# Scenario xx3 - same as xx1 but publish from multiple nodes
# To compare FloodSub and GossipSub factor
for i in 0..<topicAmount:
  os.sleep(50)
  # TODO: This would then publish on a subtopic here
  var s = "hello " & $2
  var res3 = waitFor nodes[0].wakuPublish("waku", s & "0")
  res3 = waitFor nodes[1].wakuPublish("waku", s & "1")
  res3 = waitFor nodes[2].wakuPublish("waku", s & "2")
  res3 = waitFor nodes[3].wakuPublish("waku", s & "3")
  res3 = waitFor nodes[4].wakuPublish("waku", s & "4")

# Scenario xx2 - 14 full nodes, two edge nodes
# Assume one full topic
#########################################
#let nodea = newRpcHttpClient()
#let nodeb = newRpcHttpClient()
#
#waitFor nodea.connect("localhost", Port(8545))
#waitFor nodeb.connect("localhost", Port(8546))
#
#let version = waitFor nodea.wakuVersion()
#info "Version is", version
#
#let res1 = waitFor nodea.wakuSubscribe("waku")
#let res2 = waitFor nodeb.wakuSubscribe("waku")
#
#let amount = 14
#var nodes: seq[RPCHttpClient]
#for i in 0..<amount:
#  var node = newRpcHttpClient()
#  nodes.add(node)
#  waitFor nodes[i].connect("localhost", Port(8547+i))
#  var res = waitFor nodes[i].wakuSubscribe("waku")
#
#os.sleep(2000)
#
## TODO: Show plaintext message in log
#for i in 0..<topicAmount:
#  os.sleep(50)
#  # TODO: This would then publish on a subtopic here
#  var s = "hello " & $2
#  var res3 = waitFor nodea.wakuPublish("waku", s)

# Misc old scenarios
#########################################

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

# Node 00 and 05 also subscribe
# XXX I confirm this works. As in - with this we have A-B
#  Now to tweak it!
# let node0 = newRpcHttpClient()
# let node5 = newRpcHttpClient()
# waitFor node0.connect("localhost", Port(8547))
# waitFor node5.connect("localhost", Port(8552))
# let res4 = waitFor node0.wakuSubscribe("foobar")
# let res5 = waitFor node5.wakuSubscribe("foobar")
