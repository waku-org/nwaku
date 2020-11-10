import
  json_rpc/rpcserver,
  eth/async_utils,
  waku_api_tools, waku_api_types,
  ../waku_types,../wakunode2

proc setupWakuRPCAPI*(node: WakuNode, rpcsrv: RpcServer) =
  
  rpcsrv.rpc("get_waku_v2_store_query") do(query: HistoryQueryAPI) -> HistoryResponseAPI:
    ## Returns history for a list of topics
    debug "get_waku_v2_store_query"

    var responseFut = newFuture[HistoryResponseAPI]()
 
    proc queryFuncHandler(response: HistoryResponse) {.gcsafe, closure.} =
      debug "get_waku_v2_store_query response"
      responseFut.complete(response.convertToAPI())
    
    let historyQuery = query.convertFromAPI()
    await node.query(historyQuery, queryFuncHandler)

    if (await responseFut.withTimeout(5.seconds)):
      # Future completed
      result = responseFut.read()
    else:
      # Future failed to complete
      raise newException(ValueError, "No history response received")

