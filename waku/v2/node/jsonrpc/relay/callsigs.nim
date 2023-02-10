# Relay API

proc post_waku_v2_relay_v1_message(topic: string, message: WakuRelayMessage): bool
proc get_waku_v2_relay_v1_messages(topic: string): seq[WakuMessage]
proc post_waku_v2_relay_v1_subscriptions(topics: seq[string]): bool
proc delete_waku_v2_relay_v1_subscriptions(topics: seq[string]): bool


# Relay Private API
# Symmetric
proc get_waku_v2_private_v1_symmetric_key(): SymKey
proc post_waku_v2_private_v1_symmetric_message(topic: string, message: WakuRelayMessage, symkey: string): bool
proc get_waku_v2_private_v1_symmetric_messages(topic: string, symkey: string): seq[WakuRelayMessage]
# Asymmetric
proc get_waku_v2_private_v1_asymmetric_keypair(): WakuKeyPair
proc post_waku_v2_private_v1_asymmetric_message(topic: string, message: WakuRelayMessage, publicKey: string): bool
proc get_waku_v2_private_v1_asymmetric_messages(topic: string, privateKey: string): seq[WakuRelayMessage]
