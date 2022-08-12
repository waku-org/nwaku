import
  os, strutils, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  libp2p/protobuf/minprotobuf,
  libp2p/[peerinfo, multiaddress],
  eth/common as eth_common, eth/keys,
  system,
  options,
  ../wakunode2,
  ../waku_payload,
  ../jsonrpc/jsonrpc_types,
  ../../protocol/waku_filter,
  ../../protocol/waku_store,
  ../../../v1/node/rpc/hexstrings

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "../jsonrpc/jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

var node = newRpcHttpClient()
waitfor node.connect("localhost", Port(8545))

var res = waitfor node.get_waku_v2_debug_v1_info()
echo "Waku info res: ", res
