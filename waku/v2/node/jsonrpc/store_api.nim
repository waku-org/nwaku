when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sequtils],
  chronicles,
  json_rpc/rpcserver
import
  ../../protocol/waku_store,
  ../../protocol/waku_store/rpc,
  ../../utils/time,
  ../waku_node,
  ../peer_manager/peer_manager,
  ./jsonrpc_types, 
  ./jsonrpc_utils

export jsonrpc_types

logScope:
  topics = "waku node jsonrpc store_api"

proc installStoreApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  const futTimeout = 5.seconds

  ## Store API version 1 definitions

  rpcsrv.rpc("get_waku_v2_store_v1_messages") do (pubsubTopicOption: Option[string], contentFiltersOption: Option[seq[HistoryContentFilterRPC]], startTime: Option[Timestamp], endTime: Option[Timestamp], pagingOptions: Option[StorePagingOptions]) -> StoreResponse:
    ## Returns history for a list of content topics with optional paging
    debug "get_waku_v2_store_v1_messages"

    let peerOpt = node.peerManager.selectPeer(WakuStoreCodec)
    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote store peers")

    let req = HistoryQuery(
      pubsubTopic: pubsubTopicOption,
      contentTopics: if contentFiltersOption.isNone(): @[]
                     else: contentFiltersOption.get().mapIt(it.contentTopic),
      startTime: startTime,
      endTime: endTime,
      ascending: if pagingOptions.isNone(): true
                 else: pagingOptions.get().forward,
      pageSize: if pagingOptions.isNone(): DefaultPageSize
                else: min(pagingOptions.get().pageSize, MaxPageSize),
      cursor: if pagingOptions.isNone(): none(HistoryCursor)
              else: pagingOptions.get().cursor.map(toAPI)
    )

    let queryFut = node.query(req, peerOpt.get())

    if not await queryFut.withTimeout(futTimeout):
      raise newException(ValueError, "No history response received (timeout)")
    
    let res = queryFut.read()
    if res.isErr():
      raise newException(ValueError, $res.error)

    debug "get_waku_v2_store_v1_messages response"
    return res.value.toJsonRPCStoreResponse()
