# Store API

proc get_waku_v2_store_v1_messages(pubsubTopicOption: Option[string], contentFiltersOption: Option[seq[HistoryContentFilterRPC]], startTime: Option[Timestamp], endTime: Option[Timestamp], pagingOptions: Option[StorePagingOptions]): StoreResponse

