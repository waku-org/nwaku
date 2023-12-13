when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sequtils],
  chronicles,
  json_rpc/rpcserver
import
  ../../../[
    waku_core,
    waku_store,
    waku_node
  ],
  ../../../waku_store/rpc,
  ../../../node/peer_manager,
  ../../../common/paging,
  ./types


logScope:
  topics = "waku node jsonrpc store_api"


const futTimeout = 5.seconds


proc toPagingInfo*(pagingOptions: StorePagingOptions): PagingInfoRPC =
  PagingInfoRPC(
    pageSize: some(pagingOptions.pageSize),
    cursor: pagingOptions.cursor,
    direction: some(pagingOptions.forward.into())
  )

proc toPagingOptions*(pagingInfo: PagingInfoRPC): StorePagingOptions =
  StorePagingOptions(
    pageSize: pagingInfo.pageSize.get(0'u64),
    cursor: pagingInfo.cursor,
    forward: pagingInfo.direction.into()
  )

proc toJsonRPCStoreResponse*(response: HistoryResponse): StoreResponse =
  StoreResponse(
    messages: response.messages.map(toWakuMessageRPC),
    pagingOptions: if response.cursor.isNone(): none(StorePagingOptions)
                   else: some(StorePagingOptions(
                     pageSize: uint64(response.messages.len), # This field will be deprecated soon
                     forward: true,  # Hardcoded. This field will be deprecated soon
                     cursor: response.cursor.map(toRPC)
                   ))
  )

proc installStoreApiHandlers*(node: WakuNode, server: RpcServer) =

  server.rpc("get_waku_v2_store_v1_messages") do (pubsubTopicOption: Option[string], contentFiltersOption: Option[seq[HistoryContentFilterRPC]], startTime: Option[Timestamp], endTime: Option[Timestamp], pagingOptions: Option[StorePagingOptions]) -> StoreResponse:
    ## Returns history for a list of content topics with optional paging
    debug "get_waku_v2_store_v1_messages"

    let peerOpt = node.peerManager.selectPeer(WakuStoreCodec)
    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote store peers")

    let req = HistoryQuery(
      pubsubTopic: pubsubTopicOption,
      contentTopics: contentFiltersOption.get(@[]).mapIt(it.contentTopic),
      startTime: startTime,
      endTime: endTime,
      direction: if pagingOptions.isNone(): default()
                 else: pagingOptions.get().forward.into(),
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

    return res.value.toJsonRPCStoreResponse()
