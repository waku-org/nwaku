import
  os, strutils, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  libp2p/protobuf/minprotobuf,
  eth/common as eth_common, eth/keys,
  system,
  options
import
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/waku_payload,
  ../../waku/v2/node/jsonrpc/jsonrpc_types,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v1/node/rpc/hexstrings



from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "../jsonrpc/jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

if paramCount() < 1:
  echo "Please provide rpcPort as argument."
  quit(1)

let rpcPort = Port(parseInt(paramStr(1)))

var client = newRpcHttpClient()
waitfor client.connect("localhost", rpcPort)

echo "Subscribing"

# Subscribe to waku topic
var res = waitFor client.post_waku_v2_relay_v1_subscriptions(@["/waku/2/default-waku/proto"])
echo res
