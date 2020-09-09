import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  libp2p/protobuf/minprotobuf,
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

var node = newRpcHttpClient()
waitfor node.connect("localhost", rpcPort)

# Subscribe to waku topic
var res = node.wakuSubscribe("waku")
