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

declarePublicGauge lpt_receiver_latencies,
  "Message delivery latency per peer (min-avg-max)", ["peer", "latency"]

declarePublicCounter lpt_receiver_lost_subscription_count,
  "number of filter service peer failed PING requests - lost subscription"

declarePublicCounter lpt_publisher_sent_messages_count, "number of messages published"

declarePublicCounter lpt_publisher_failed_messages_count,
  "number of messages failed to publish per failure cause", ["cause"]

declarePublicCounter lpt_publisher_sent_bytes, "number of total bytes sent"

declarePublicCounter lpt_service_peer_failure_count,
  "number of failure during using service peer [publisher/receiever]", ["role"]

declarePublicCounter lpt_change_service_peer_count,
  "number of times [publisher/receiver] had to change service peer", ["role"]

declarePublicGauge lpt_px_peers,
  "Number of peers PeerExchange discovered and can be dialed"

declarePublicGauge lpt_dialed_peers, "Number of peers successfully dialed"

declarePublicGauge lpt_dial_failures, "Number of dial failures by cause"
