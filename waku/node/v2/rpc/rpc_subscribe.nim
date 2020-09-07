import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  libp2p/protobuf/minprotobuf,
  eth/common as eth_common, eth/keys,
  options

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

proc message(i: int): ProtoBuffer =
  let value = "hello " & $(i)

  var result = initProtoBuffer()
  result.write(initProtoField(1, value))
  result.finish()

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

var node = newRpcHttpClient()
waitfor node.connect("localhost", Port(8545))

# Subscribe to waku topic
var res = node.wakuSubscribe("waku")
