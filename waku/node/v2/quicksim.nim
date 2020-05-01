import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys,
  # XXX: Replace me
  eth/p2p/rlpx_protocols/waku_protocol,
  ../v0/rpc/[hexstrings, rpc_types, waku],
  rpc/wakurpc,
  options as what # TODO: Huh? Redefinition?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

# More minimal than v0 quicksim, just RPC client for now

let node1 = newRpcHttpClient()
#let node2 = newRpcHttpClient()

# Where do we connect nodes here? Protocol so not RPC based, maybe?
# Using with static nodes, hardcoded "works":
# /ip4/127.0.0.1/tcp/55505/ipfs/16Uiu2HAkufRTzUnYCMggjPaAMbC3ss1bkrjewPcjwSeqK9WgUKYu

# static node parsing ignored for now
#./build/wakunode2 --staticnode:/ip4/hallibaba/foo --ports-shift:1

# node 1:
#  WRN 2020-05-01 12:20:13+08:00 no handlers for                            tid=24636 protocol=/vac/waku/2.0.0-alpha0 topic=Multistream




# Need to figure out rw stuff as well, perhaps we can start a few nodes and see if we get some pingpong
# Unclear how to mount waku on top of gossipsub tho

info "Hello there"
# Hello world
waitFor node1.connect("localhost", Port(8545))

let version = waitFor node1.wakuVersion()

info "Version is", version
