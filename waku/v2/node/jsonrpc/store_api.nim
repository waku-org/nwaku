{.push raises: [Defect].}

import
  std/options,
  chronicles,
  json_rpc/rpcserver
import
  ../peer_manager/peer_manager,
  ../waku_node,
  ../../protocol/waku_store,
  ../../utils/time,
  ./jsonrpc_types, 
  ./jsonrpc_utils

export jsonrpc_types

logScope:
  topics = "store api"

proc installStoreApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  const futTimeout = 5.seconds

  ## Store API version 1 definitions

  rpcsrv.rpc("get_waku_v2_store_v1_messages") do (pubsubTopicOption: Option[string], contentFiltersOption: Option[seq[HistoryContentFilter]], startTime: Option[Timestamp], endTime: Option[Timestamp], pagingOptions: Option[StorePagingOptions]) -> StoreResponse:
    ## Returns history for a list of content topics with optional paging
    debug "get_waku_v2_store_v1_messages"

    let peerOpt = node.peerManager.selectPeer(WakuStoreCodec)
    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote store peers")

    let historyQuery = HistoryQuery(pubsubTopic: if pubsubTopicOption.isSome: pubsubTopicOption.get() else: "",
                                    contentFilters: if contentFiltersOption.isSome: contentFiltersOption.get() else: @[],
                                    startTime: if startTime.isSome: startTime.get() else: Timestamp(0),
                                    endTime: if endTime.isSome: endTime.get() else: Timestamp(0),
                                    pagingInfo: if pagingOptions.isSome: pagingOptions.get.toPagingInfo() else: PagingInfo())
    let queryFut = node.query(historyQuery, peerOpt.get())

    if not await queryFut.withTimeout(futTimeout):
      raise newException(ValueError, "No history response received (timeout)")
    
    let res = queryFut.read()
    if res.isErr():
      raise newException(ValueError, $res.error)

    debug "get_waku_v2_store_v1_messages response"
    return res.value.toStoreResponse()
