import
  std/[os, strutils, times, options], #options as what # TODO: Huh? Redefinition?
  chronicles, 
  eth/common as eth_common, 
  eth/keys,
  json_rpc/[rpcclient, rpcserver],
  libp2p/protobuf/minprotobuf
import
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/utils/time,
  ../../waku/v2/node/wakunode2, 
  ../../waku/v2/node/waku_payload,
  ../../waku/v2/node/jsonrpc/[jsonrpc_types,jsonrpc_utils]
  

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / ".." / ".." / "waku" / "v2" / "node" / "jsonrpc" / "jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

const defaultTopic = "/waku/2/default-waku/proto"

const defaultContentTopic = ContentTopic("waku/2/default-content/proto")

const topicAmount = 10 #100

proc message(i: int): ProtoBuffer =
  let value = "hello " & $(i)

  var result = initProtoBuffer()
  result.write(1, value)
  result.finish()

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

# Scenario xx1 - 16 full nodes
#########################################
let amount = 16
var nodes: seq[RPCHttpClient]
for i in 0..<amount:
  var node = newRpcHttpClient()
  nodes.add(node)
  waitFor nodes[i].connect("localhost", Port(8547+i), false)
  var res = waitFor nodes[i].post_waku_v2_relay_v1_subscriptions(@[defaultTopic])

os.sleep(2000)

# # TODO: Show plaintext message in log
# for i in 0..<topicAmount:
#   os.sleep(50)
#   # TODO: This would then publish on a subtopic here
#   var s = "hello " & $2
#   var res3 = waitFor nodes[0].wakuPublish(defaultTopic, s)

# Scenario xx3 - same as xx1 but publish from multiple nodes
# To compare FloodSub and GossipSub factor
for i in 0..<topicAmount:
  os.sleep(50)
  # TODO: This would then publish on a subtopic here
  var res3 = waitFor nodes[0].post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: message(0).buffer, contentTopic: some(defaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))
  res3 = waitFor nodes[1].post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: message(1).buffer, contentTopic: some(defaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))
  res3 = waitFor nodes[2].post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: message(2).buffer, contentTopic: some(defaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))
  res3 = waitFor nodes[3].post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: message(3).buffer, contentTopic: some(defaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))
  res3 = waitFor nodes[4].post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: message(4).buffer, contentTopic: some(defaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))

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
#let res1 = waitFor nodea.wakuSubscribe(defaultTopic)
#let res2 = waitFor nodeb.wakuSubscribe(defaultTopic)
#
#let amount = 14
#var nodes: seq[RPCHttpClient]
#for i in 0..<amount:
#  var node = newRpcHttpClient()
#  nodes.add(node)
#  waitFor nodes[i].connect("localhost", Port(8547+i))
#  var res = waitFor nodes[i].wakuSubscribe(defaultTopic)
#
#os.sleep(2000)
#
## TODO: Show plaintext message in log
#for i in 0..<topicAmount:
#  os.sleep(50)
#  # TODO: This would then publish on a subtopic here
#  var s = "hello " & $2
#  var res3 = waitFor nodea.wakuPublish(defaultTopic, s)

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
