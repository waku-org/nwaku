# Relay API
proc post_waku_v2_relay_v1_subscriptions(topics: seq[PubsubTopic]): bool
proc delete_waku_v2_relay_v1_subscriptions(topics: seq[PubsubTopic]): bool
proc post_waku_v2_relay_v1_message(topic: PubsubTopic, message: WakuMessageRPC): bool
proc get_waku_v2_relay_v1_messages(topic: PubsubTopic): seq[WakuMessageRPC]

proc post_waku_v2_relay_v1_auto_subscriptions(topics: seq[ContentTopic]): bool
proc delete_waku_v2_relay_v1_auto_subscriptions(topics: seq[ContentTopic]): bool
proc post_waku_v2_relay_v1_auto_message(message: WakuMessageRPC): bool
proc get_waku_v2_relay_v1_auto_messages(topic: ContentTopic): seq[WakuMessageRPC]


# Support for the Relay Private API has been deprecated.
# This API existed for compatibility with the Waku v1 spec and encryption scheme.
