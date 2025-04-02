{.push raises: [].}

import metrics

declarePublicGauge waku_archive_messages, "number of historical messages", ["type"]
declarePublicGauge waku_archive_messages_per_shard,
  "number of historical messages per shard ", ["shard"]
declarePublicHistogram waku_archive_insert_duration_seconds,
  "message insertion duration"
declarePublicHistogram waku_archive_query_duration_seconds, "history query duration"

# Error types (metric label values)
const
  invalidMessageOld* = "invalid_message_too_old"
  invalidMessageFuture* = "invalid_message_future_timestamp"
  insertFailure* = "insert_failure"
  retPolicyFailure* = "retpolicy_failure"
