# Relay API
proc post_waku_v2_relay_v1_subscriptions(topics: seq[PubsubTopic]): bool
proc delete_waku_v2_relay_v1_subscriptions(topics: seq[PubsubTopic]): bool
proc post_waku_v2_relay_v1_message(topic: PubsubTopic, message: WakuMessageRPC): bool
proc get_waku_v2_relay_v1_messages(topic: PubsubTopic): seq[WakuMessageRPC]


# Relay Private API
# Symmetric
proc get_waku_v2_private_v1_symmetric_key(): SymKey
proc post_waku_v2_private_v1_symmetric_message(topic: string, message: WakuMessageRPC, symkey: string): bool
proc get_waku_v2_private_v1_symmetric_messages(topic: string, symkey: string): seq[WakuMessageRPC]
# Asymmetric
proc get_waku_v2_private_v1_asymmetric_keypair(): WakuKeyPair
proc post_waku_v2_private_v1_asymmetric_message(topic: string, message: WakuMessageRPC, publicKey: string): bool
proc get_waku_v2_private_v1_asymmetric_messages(topic: string, privateKey: string): seq[WakuMessageRPC]
