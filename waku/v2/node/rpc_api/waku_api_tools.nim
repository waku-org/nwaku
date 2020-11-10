import
  waku_api_types,
  options,
  ../wakunode2

## Conversion tools
## Since the Waku v2 JSON-RPC API has its own defined types,
## we need to convert between these and the types for the Nim API
proc convertToAPI*(response: HistoryResponse): HistoryResponseAPI =
  if response.pagingInfo != PagingInfo():
    # PagingInfo is not empty. Set pagingInfo Option on API response.
    result = HistoryResponseAPI(messages: response.messages, pagingInfo: some(response.pagingInfo))
  else:
    result = HistoryResponseAPI(messages: response.messages, pagingInfo: none(PagingInfo))

proc convertFromAPI*(query: HistoryQueryAPI): HistoryQuery =
  if query.pagingInfo.isSome:
    # PagingInfo Option is set. Add paging info to query.
    result = HistoryQuery(topics: query.topics, pagingInfo: query.pagingInfo.get)
  else:
    result = HistoryQuery(topics: query.topics)