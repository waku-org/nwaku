import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  stew/shims/net as stewNet, stew/byteutils,
  libp2p/protobuf/minprotobuf,
  eth/common as eth_common, eth/keys,
  system,
  strformat,
  ../waku_types,
  options

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

if paramCount() < 1:
  echo "Please provide rpcPort as argument."
  quit(1)

let rpcPort = Port(parseInt(paramStr(1)))

echo "Please enter your message:"
let raw_input = readLine(stdin)
let input = fmt"{raw_input}"
echo "Input is:", input

var client = newRpcHttpClient()
waitfor client.connect("localhost", rpcPort)

# Subscribe ourselves to topic
#var res = node.wakuSubscribe("waku")

let
  pubSubTopic = "waku"
  contentTopic = "foobar"
  contentFilter = ContentFilter(topics: @[contentTopic])
  message = WakuMessage(payload: input.toBytes(),
                        contentTopic: contentTopic)

# TODO When RPC uses Node, create WakuMessage and pass instead
#var res2 = waitfor node.wakuPublish("waku", cast[seq[byte]]("hello world"))
#
var res2 = waitfor client.wakuPublish2(pubSubTopic, message)
#node.publish(pubSubTopic, message)
