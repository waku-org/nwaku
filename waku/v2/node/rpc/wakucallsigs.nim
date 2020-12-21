# Alpha - Currently implemented in v2
proc waku_version(): string
# TODO Deprecate old waku_publish, requires adjust simulation code etc
proc waku_publish(topic: string, message: seq[byte]): bool
# TODO This should be properly done with rpc types, etc.
proc waku_publish2(topic: string, message: seq[byte]): bool
proc waku_subscribe(topic: string): bool
proc waku_query(topics: seq[string]): bool
proc waku_subscribe_filter(topic: string, contentFilters: seq[seq[string]]): bool
#proc waku_subscribe(topic: string, handler: Topichandler): bool
#
# TODO turn into WakuInfo object
proc waku_info(): string

# NYI
#proc waku_info(): WakuInfo
#proc waku_setMaxMessageSize(size: uint64): bool
#proc waku_setMinPoW(pow: float): bool
#proc waku_markTrustedPeer(enode: string): bool
#
#proc waku_newKeyPair(): Identifier
#proc waku_addPrivateKey(key: string): Identifier
#proc waku_deleteKeyPair(id: Identifier): bool
#proc waku_hasKeyPair(id: Identifier): bool
#proc waku_getPublicKey(id: Identifier): PublicKey
#proc waku_getPrivateKey(id: Identifier): PrivateKey
#
#proc waku_newSymKey(): Identifier
#proc waku_addSymKey(key: string): Identifier
#proc waku_generateSymKeyFromPassword(password: string): Identifier
#proc waku_hasSymKey(id: Identifier): bool
#proc waku_getSymKey(id: Identifier): SymKey
#proc waku_deleteSymKey(id: Identifier): bool
#
#proc waku_newMessageFilter(options: WakuFilterOptions): Identifier
#proc waku_deleteMessageFilter(id: Identifier): bool
#proc waku_getFilterMessages(id: Identifier): seq[WakuFilterMessage]
##proc waku_post(message: WakuPostMessage): bool
#
#proc wakusim_generateTraffic(amount: int): bool
#proc wakusim_generateRandomTraffic(amount: int): bool
