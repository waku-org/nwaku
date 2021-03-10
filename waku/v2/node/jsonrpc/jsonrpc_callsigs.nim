# Admin API

proc get_waku_v2_admin_v1_peers(): seq[WakuPeer]
proc post_waku_v2_admin_v1_peers(peers: seq[string]): bool

# Debug API

proc get_waku_v2_debug_v1_info(): WakuInfo

# Relay API

proc post_waku_v2_relay_v1_message(topic: string, message: WakuRelayMessage): bool
proc get_waku_v2_relay_v1_messages(topic: string): seq[WakuMessage]
proc post_waku_v2_relay_v1_subscriptions(topics: seq[string]): bool
proc delete_waku_v2_relay_v1_subscriptions(topics: seq[string]): bool

# Store API

proc get_waku_v2_store_v1_messages(topics: seq[ContentTopic], pagingOptions: Option[StorePagingOptions]): StoreResponse

# Filter API

proc get_waku_v2_filter_v1_messages(contentTopic: ContentTopic): seq[WakuMessage]
proc post_waku_v2_filter_v1_subscription(contentFilters: seq[ContentFilter], topic: Option[string]): bool
proc delete_waku_v2_filter_v1_subscription(contentFilters: seq[ContentFilter], topic: Option[string]): bool

# Private API
# Symmetric
proc get_waku_v2_private_v1_symmetric_key(): SymKey
proc post_waku_v2_private_v1_symmetric_message(topic: string, message: WakuRelayMessage, symkey: string): bool
proc get_waku_v2_private_v1_symmetric_messages(topic: string, symkey: string): seq[WakuRelayMessage]
# Asymmetric
proc get_waku_v2_private_v1_asymmetric_keypair(): WakuKeyPair
proc post_waku_v2_private_v1_asymmetric_message(topic: string, message: WakuRelayMessage, publicKey: string): bool
proc get_waku_v2_private_v1_asymmetric_messages(topic: string, privateKey: string): seq[WakuRelayMessage]
