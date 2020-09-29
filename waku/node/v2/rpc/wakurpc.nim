import
  std/options,
  json_rpc/rpcserver,
  nimcrypto/[sysrand, hmac, sha2],
  eth/[common, rlp, keys, p2p],
  ../../../protocol/v2/waku_relay,
  ../waku_types, ../wakunode2

# Instead of using rlpx waku_protocol here, lets do mock waku2_protocol
# This should wrap GossipSub, not use EthereumNode here

# In Waku0/1 we use node.protocolState(Waku) a lot to get information
# Also keys to get priate key, etc
# Where is the equivalent in Waku/2?
# TODO: Extend to get access to protocol state and keys
#proc setupWakuRPC*(node: EthereumNode, keys: KeyStorage, rpcsrv: RpcServer) =
proc setupWakuRPC*(node: WakuNode, rpcsrv: RpcServer) =

  # Seems easy enough, lets try to get this first
  rpcsrv.rpc("waku_version") do() -> string:
     ## Returns string of the current Waku protocol version.
     result = WakuRelayCodec

  # TODO: Implement symkey etc logic
  rpcsrv.rpc("waku_publish") do(topic: string, payload: seq[byte]) -> bool:
    let wakuRelay = node.wakuRelay
    # XXX also future return type
    # TODO: Shouldn't we really be doing WakuNode publish here?
    debug "waku_publish", topic=topic, payload=payload
    discard wakuRelay.publish(topic, payload)
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

  rpcsrv.rpc("waku_publish2") do(topic: string, payload: seq[byte]) -> bool:
    let msg = WakuMessage.init(payload)
    if msg.isOk():
      debug "waku_publish", msg=msg
    else:
      warn "waku_publish decode error", msg=msg

    debug "waku_publish", topic=topic, payload=payload, msg=msg[]
    node.publish(topic, msg[])
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

  # TODO: Handler / Identifier logic
  rpcsrv.rpc("waku_subscribe") do(topic: string) -> bool:
    debug "waku_subscribe", topic=topic

    # XXX: Hacky in-line handler
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        debug "waku_subscribe handler", msg=msg
        var readable_str = cast[string](msg[].payload)
        info "Hit subscribe handler", topic=topic, msg=msg[], payload=readable_str
      else:
        warn "waku_subscribe decode error", msg=msg
        info "waku_subscribe raw data string", str=cast[string](data)

    # XXX: Can we make this context async to use await?
    discard node.subscribe(topic, handler)
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

  rpcsrv.rpc("waku_query") do(topics: seq[string]) -> bool:
    debug "waku_query"

    # XXX: Hacky in-line handler
    proc handler(response: HistoryResponse) {.gcsafe.} =
      info "Hit response handler", messages=response.messages

    await node.query(HistoryQuery(topics: topics), handler)
    return true
  
  rpcsrv.rpc("waku_filter") do(topic: string, contentTopics: seq[seq[string]]) -> bool:
    debug "waku_filter"

    # XXX: Hacky in-line handler
    proc handler(msg: MessagePush) {.gcsafe, closure.} -
      info "Hit filter response", nessages=msg.messages

    var content = newSeq[ContentFilter]()
    for topics in contentTopics:
      content.add(ContentFilter(topics: topics))

    await node.filter(FilterRequest(topic: topic, contentTopics: content), handler)
    return true
