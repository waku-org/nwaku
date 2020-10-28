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
let raw_input = readLine(stdin)
let input = fmt"{raw_input}"
echo "Input is:", input

var node = newRpcHttpClient()
waitfor node.connect("localhost", rpcPort)

let pubSubTopic = "/waku/2/default-waku/proto"
let contentTopic = "foobar"
var wakuMessage = WakuMessage(payload: input.toBytes(), contentTopic: contentTopic)
# XXX This should be WakuMessage type, but need to setup JSON-RPC mapping for that to work
var raw_bytes = wakuMessage.encode().buffer
var res = waitfor node.wakuPublish2(pubSubTopic, raw_bytes)
echo "Waku publish response: ", res
