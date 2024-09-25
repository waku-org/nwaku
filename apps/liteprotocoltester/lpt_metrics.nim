## Example showing how a resource restricted client may
## subscribe to messages without relay

import metrics

export metrics

declarePublicGauge lpt_receiver_sender_peer_count, "count of sender peers"

declarePublicCounter lpt_receiver_received_messages_count,
  "number of messages received per peer", ["peer"]

declarePublicCounter lpt_receiver_received_bytes,
  "number of received bytes per peer", ["peer"]

declarePublicGauge lpt_receiver_missing_messages_count,
  "number of missing messages per peer", ["peer"]

declarePublicCounter lpt_receiver_duplicate_messages_count,
  "number of duplicate messages per peer", ["peer"]

declarePublicGauge lpt_receiver_distinct_duplicate_messages_count,
  "number of distinct duplicate messages per peer", ["peer"]

declarePublicCounter lpt_publisher_sent_messages_count, "number of messages published"

declarePublicCounter lpt_publisher_failed_messages_count,
  "number of messages failed to publish per failure cause", ["cause"]

declarePublicCounter lpt_publisher_sent_bytes, "number of total bytes sent"
