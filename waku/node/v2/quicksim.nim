import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys,
  ../v1/rpc/[hexstrings, rpc_types],
  options as what # TODO: Huh? Redefinition?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

let node1 = newRpcHttpClient()
let node2 = newRpcHttpClient()

info "Hello there"

# portsShift=2
waitFor node1.connect("localhost", Port(8547))
waitFor node2.connect("localhost", Port(8548))

let version = waitFor node1.wakuVersion()

proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  debug "Hit handler", topic=topic, data=data

# TODO: Implement handler logic
let res1 = waitFor node2.wakuSubscribe("foobar")
os.sleep(2000)
let res2 = waitFor node1.wakuPublish("foobar", "hello world")
os.sleep(2000)
info "Version is", version
