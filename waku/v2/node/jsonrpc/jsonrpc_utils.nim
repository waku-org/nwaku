import
  std/options,
  ../../waku_types,
  ../../protocol/waku_store/waku_store_types,
  ../wakunode2,
  ./jsonrpc_types

## Conversion tools
## Since the Waku v2 JSON-RPC API has its own defined types,
## we need to convert between these and the types for the Nim API

proc toPagingInfo*(pagingOptions: StorePagingOptions): PagingInfo =
  PagingInfo(pageSize: pagingOptions.pageSize,
             cursor: if pagingOptions.cursor.isSome: pagingOptions.cursor.get else: Index(),
             direction: if pagingOptions.forward: PagingDirection.FORWARD else: PagingDirection.BACKWARD)

proc toPagingOptions*(pagingInfo: PagingInfo): StorePagingOptions =
  StorePagingOptions(pageSize: pagingInfo.pageSize,
                     cursor: some(pagingInfo.cursor),
                     forward: if pagingInfo.direction == PagingDirection.FORWARD: true else: false)

proc toStoreResponse*(historyResponse: HistoryResponse): StoreResponse =
  StoreResponse(messages: historyResponse.messages,
                pagingOptions: if historyResponse.pagingInfo != PagingInfo(): some(historyResponse.pagingInfo.toPagingOptions()) else: none(StorePagingOptions))

proc toWakuMessage*(relayMessage: WakuRelayMessage, version: uint32): WakuMessage =
  # @TODO global definition for default content topic
  const defaultCT = 0
  WakuMessage(payload: relayMessage.payload,
              contentTopic: if relayMessage.contentTopic.isSome: relayMessage.contentTopic.get else: defaultCT,
              version: version)
