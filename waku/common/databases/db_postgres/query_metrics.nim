import metrics

declarePublicGauge query_time_secs,
  "query time measured in nanoseconds", labels = ["query", "phase"]

declarePublicCounter query_count,
  "number of times a query is being performed", labels = ["query"]

## Possible labels
## The above metrics can only use the following labels
const ContentTopicQuery = "content_topic"
const SelectVersionQuery = "select_version"
const MessagesLookupQuery = "messages_lookup"
const MsgHashWithoutContentTopicQuery = "msg_hash_no_ctopic"
const MsgHashWithCursorQuery = "msg_hash_with_cursor"
const GetPartitionsListQuery = "get_partitions_list"
const CountMsgsQuery = "count_msgs"
const GetDatabaseSizeQuery = "get_database_size"
const DeleteFromMessagesLookupQuery = "delete_from_msgs_lookup"
const DropPartitionTableQuery = "drop_partition_table"
const DetachPartitionQuery = "detach_partition"
const GetPartitionSizeQuery = "get_partition_size"
const TryAdvisoryLockQuery = "try_advisory_lock"
const GetAllMsgHashQuery = "get_all_msg_hash"
const AdvisoryUnlockQuery = "advisory_unlock"
const AnalyzeMessagesQuery = "analyze_messages"
const CheckVersionTableExistsQuery = "check_version_table_exists"

## Maps parts of the possible known queries with a fixed and shorter query label.
const QueriesToMetricMap* = {
  "contentTopic IN": ContentTopicQuery,
  "SELECT version()": SelectVersionQuery,
  "WITH min_timestamp": MessagesLookupQuery,
  "SELECT messageHash FROM messages WHERE pubsubTopic = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC, messageHash DESC LIMIT ?": MsgHashWithoutContentTopicQuery,
  "AS partition_name": GetPartitionsListQuery,
  "SELECT COUNT(1) FROM messages": CountMsgsQuery,
  "SELECT messageHash FROM messages WHERE (timestamp, messageHash) < (?,?) AND pubsubTopic = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC, messageHash DESC LIMIT ?": MsgHashWithCursorQuery,
  "SELECT pg_database_size(current_database())": GetDatabaseSizeQuery,
  "DELETE FROM messages_lookup WHERE timestamp": DeleteFromMessagesLookupQuery,
  "DROP TABLE messages_": DropPartitionTableQuery,
  "ALTER TABLE messages DETACH PARTITION": DetachPartitionQuery,
  "SELECT pg_size_pretty(pg_total_relation_size(C.oid))": GetPartitionSizeQuery,
  "pg_try_advisory_lock": TryAdvisoryLockQuery,
  "SELECT messageHash FROM messages ORDER BY timestamp DESC, messageHash DESC LIMIT ?": GetAllMsgHashQuery,
  "SELECT pg_advisory_unlock": AdvisoryUnlockQuery,
  "ANALYZE messages": AnalyzeMessagesQuery,
  "SELECT EXISTS": CheckVersionTableExistsQuery
}
