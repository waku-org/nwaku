import
  os, strutils, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  libp2p/protobuf/minprotobuf,
  libp2p/[peerinfo, multiaddress],
  eth/common as eth_common, eth/keys,
  system,
  options,
  ../wakunode2,
  ../waku_payload,
  ../jsonrpc/jsonrpc_types,
  ../../protocol/waku_filter/waku_filter_types,
  ../../protocol/waku_store/waku_store_types,
  ../../../v1/node/rpc/hexstrings

from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = sourceDir / "../jsonrpc/jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

if paramCount() < 1:
  echo "Please provide rpcPort as argument."
  quit(1)

let rpcPort = Port(parseInt(paramStr(1)))

echo "Please enter your pubsub topic:"
let raw_pubsub = readLine(stdin)
let pubsubTopic = fmt"{raw_pubsub}"
echo "PubSubTopic is:", pubsubTopic

echo "Please enter your content topic:"
let raw_input = readLine(stdin)
let input = fmt"{raw_input}"
echo "Content topic is:", input

var node = newRpcHttpClient()
waitfor node.connect("localhost", rpcPort)

var res = waitfor node.get_waku_v2_store_v1_messages(pubsubTopic, @[HistoryContentFilter(contentTopic: ContentTopic(input))], none(StorePagingOptions))
echo "Waku query response: ", res
