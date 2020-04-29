import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys,
  # XXX: Replace me
  eth/p2p/rlpx_protocols/waku_protocol,
  ../../vendor/nimbus/nimbus/rpc/[hexstrings, rpc_types, waku],
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
# Could hack it I suppose

info "Hello there"
# Hello world
waitFor node1.connect("localhost", Port(8545))

let version = waitFor node1.wakuVersion()

info "Version is", version
