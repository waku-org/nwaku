{.push raises: [Defect].}

import
  std/options,
  chronicles,
  json_rpc/rpcserver,
  ../wakunode2,
  ../../utils/time,
  ./jsonrpc_types, ./jsonrpc_utils

export jsonrpc_types

logScope:
  topics = "store api"

proc installStoreApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  const futTimeout = 5.seconds

  ## Store API version 1 definitions

  rpcsrv.rpc("get_waku_v2_store_v1_messages") do(pubsubTopicOption: Option[string], contentFiltersOption: Option[seq[HistoryContentFilter]], startTime: Option[Timestamp], endTime: Option[Timestamp], pagingOptions: Option[StorePagingOptions]) -> StoreResponse:
    ## Returns history for a list of content topics with optional paging
    debug "get_waku_v2_store_v1_messages"

    var responseFut = newFuture[StoreResponse]()
 
    proc queryFuncHandler(response: HistoryResponse) {.gcsafe, closure.} =
      debug "get_waku_v2_store_v1_messages response"
      responseFut.complete(response.toStoreResponse())
    
    let historyQuery = HistoryQuery(pubsubTopic: if pubsubTopicOption.isSome: pubsubTopicOption.get() else: "",
                                    contentFilters: if contentFiltersOption.isSome: contentFiltersOption.get() else: @[],
                                    startTime: if startTime.isSome: startTime.get() else: Timestamp(0),
                                    endTime: if endTime.isSome: endTime.get() else: Timestamp(0),
                                    pagingInfo: if pagingOptions.isSome: pagingOptions.get.toPagingInfo() else: PagingInfo())
    
    await node.query(historyQuery, queryFuncHandler)

    if (await responseFut.withTimeout(futTimeout)):
      # Future completed
      return responseFut.read()
    else:
      # Future failed to complete
      raise newException(ValueError, "No history response received")