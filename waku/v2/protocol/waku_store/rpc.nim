{.push raises: [Defect].}

import
  ../../utils/time,
  ../waku_message,
  ./pagination


type
  HistoryContentFilter* = object
    contentTopic*: ContentTopic

  HistoryQuery* = object
    contentFilters*: seq[HistoryContentFilter]
    pubsubTopic*: string
    pagingInfo*: PagingInfo # used for pagination
    startTime*: Timestamp # used for time-window query
    endTime*: Timestamp # used for time-window query

  HistoryResponseError* {.pure.} = enum
    ## HistoryResponseError contains error message to inform  the querying node about the state of its request
    NONE = uint32(0)
    INVALID_CURSOR = uint32(1)
    SERVICE_UNAVAILABLE = uint32(503)

  HistoryResponse* = object
    messages*: seq[WakuMessage]
    pagingInfo*: PagingInfo # used for pagination
    error*: HistoryResponseError

  HistoryRPC* = object
    requestId*: string
    query*: HistoryQuery
    response*: HistoryResponse
