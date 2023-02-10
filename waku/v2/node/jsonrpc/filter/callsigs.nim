# Filter API

proc get_waku_v2_filter_v1_messages(contentTopic: ContentTopic): seq[WakuMessage]
proc post_waku_v2_filter_v1_subscription(contentFilters: seq[ContentFilter], topic: Option[string]): bool
proc delete_waku_v2_filter_v1_subscription(contentFilters: seq[ContentFilter], topic: Option[string]): bool
