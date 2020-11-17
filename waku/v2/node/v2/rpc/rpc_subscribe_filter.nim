import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  libp2p/protobuf/minprotobuf,
  libp2p/[peerinfo, multiaddress],
  eth/common as eth_common, eth/keys,
  system,
  options

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

if paramCount() < 1:
  echo "Please provide rpcPort as argument."
  quit(1)

let rpcPort = Port(parseInt(paramStr(1)))

echo "Please enter your topic:"
let raw_input = readLine(stdin)
let input = fmt"{raw_input}"
echo "Input is:", input

var node = newRpcHttpClient()
waitfor node.connect("localhost", rpcPort)

let pubSubTopic = "/waku/2/default-waku/proto"
let contentTopic = "foobar"
var res = waitfor node.wakuSubscribeFilter(pubSubTopic, @[@[contentTopic]])
echo "Waku query response: ", res
