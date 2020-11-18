import
  ../../waku_types,
  options

type
  HistoryQueryAPI* = object
    topics*: seq[ContentTopic]
    pagingInfo*: Option[PagingInfo] # Optional. Used for pagination

  HistoryResponseAPI* = object
    messages*: seq[WakuMessage]
    pagingInfo*: Option[PagingInfo] # Optional. Used for pagination
