import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  stew/byteutils,
  libp2p/protobuf/minprotobuf,
  eth/common as eth_common, eth/keys,
  system,
  options,
  ../wakunode2,
  ../waku_payload,
  ../jsonrpc/jsonrpc_types,
  ../../protocol/waku_filter/waku_filter_types,
  ../../protocol/waku_store,
  ../../../v1/node/rpc/hexstrings

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "../jsonrpc/jsonrpc_callsigs.nim"
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
let contentTopic = ContentTopic("/waku/2/default-content/proto")
let relayMessage = WakuRelayMessage(payload: input.toBytes(), contentTopic: some(contentTopic))
var res = waitfor node.post_waku_v2_relay_v1_message(pubSubTopic, relayMessage)
echo "Waku publish response: ", res
