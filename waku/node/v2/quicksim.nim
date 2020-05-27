import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys,
  # XXX: Replace me
  ../../protocol/v1/waku_protocol,
  ../v1/rpc/[hexstrings, rpc_types],
  options as what # TODO: Huh? Redefinition?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

# More minimal than v1 quicksim, just RPC client for now

let node1 = newRpcHttpClient()
let node2 = newRpcHttpClient()

# Where do we connect nodes here? Protocol so not RPC based, maybe?
# Using with static nodes, hardcoded "works":
# /ip4/127.0.0.1/tcp/55505/ipfs/16Uiu2HAkufRTzUnYCMggjPaAMbC3ss1bkrjewPcjwSeqK9WgUKYu

# Need to figure out rw stuff as well, perhaps we can start a few nodes and see if we get some pingpong
# Unclear how to mount waku on top of gossipsub tho

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
