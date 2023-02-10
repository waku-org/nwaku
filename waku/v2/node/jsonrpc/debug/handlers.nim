when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_rpc/rpcserver
import
  ../../../../waku/v2/node/waku_node

logScope:
  topics = "waku node jsonrpc debug_api"

proc installDebugApiHandlers*(node: WakuNode, server: RpcServer) =

  ## Debug API version 1 definitions

  server.rpc("get_waku_v2_debug_v1_info") do () -> WakuInfo:
    ## Returns information about WakuNode
    debug "get_waku_v2_debug_v1_info"

    return node.info()

  server.rpc("get_waku_v2_debug_v1_version") do () -> string:
    ## Returns information about WakuNode
    debug "get_waku_v2_debug_v1_version"

    return git_version

