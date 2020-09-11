import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  stew/byteutils,
  libp2p/protobuf/minprotobuf,
  eth/common as eth_common, eth/keys,
  system,
  options,
  ../waku_types

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

if paramCount() < 1:
  echo "Please provide rpcPort as argument."
  quit(1)

let rpcPort = Port(parseInt(paramStr(1)))

echo "Please enter your message:"
let message = readLine(stdin)
echo "Message is:", message

var node = newRpcHttpClient()
waitfor node.connect("localhost", rpcPort)

# Subscribe ourselves to topic
#var res = node.wakuSubscribe("waku")

let pubSubTopic = "waku"
let contentTopic = "foobar"
var wakuMessage = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)
var raw_bytes = wakuMessage.encode().buffer
var res = waitfor node.wakuPublish2(pubSubTopic, raw_bytes)
echo "Waku publish response: ", res
