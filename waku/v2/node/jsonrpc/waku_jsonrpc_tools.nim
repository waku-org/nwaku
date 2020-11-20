import
  ./waku_jsonrpc_types,
  std/options,
  ../wakunode2

## Conversion tools
## Since the Waku v2 JSON-RPC API has its own defined types,
## we need to convert between these and the types for the Nim API
proc convertToAPI*(response: HistoryResponse): HistoryResponseAPI =
  if response.pagingInfo != PagingInfo():
    # PagingInfo is not empty. Set pagingInfo Option on API response.
    HistoryResponseAPI(messages: response.messages, pagingInfo: some(response.pagingInfo))
  else:
    HistoryResponseAPI(messages: response.messages, pagingInfo: none(PagingInfo))

proc convertFromAPI*(query: HistoryQueryAPI): HistoryQuery =
  if query.pagingInfo.isSome:
    # PagingInfo Option is set. Add paging info to query.
    HistoryQuery(topics: query.topics, pagingInfo: query.pagingInfo.get)
  else:
    HistoryQuery(topics: query.topics)
