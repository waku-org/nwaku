import
  std/options,
  json_rpc/rpcserver,
  nimcrypto/[sysrand, hmac, sha2],
  eth/[common, rlp, keys, p2p],
  ../../protocol/waku_relay,
  ../../waku_types,
  ../../protocol/waku_store/waku_store,
  ../wakunode2

proc setupWakuRPC*(node: WakuNode, rpcsrv: RpcServer) =

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
    await node.publish(topic, msg[])
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

  rpcsrv.rpc("waku_query") do(topics: seq[int]) -> bool:
    debug "waku_query"

    # XXX: Hacky in-line handler
    proc handler(response: HistoryResponse) {.gcsafe.} =
      info "Hit response handler", messages=response.messages

    var contentTopics = newSeq[ContentTopic]()
    for topic in topics:
      contentTopics.add(ContentTopic(topic))

    await node.query(HistoryQuery(topics: contentTopics), handler)
    return true
  
  rpcsrv.rpc("waku_subscribe_filter") do(topic: string, contentFilters: seq[seq[int]]) -> bool:
    debug "waku_subscribe_filter"

    # XXX: Hacky in-line handler
    proc handler(msg: WakuMessage) {.gcsafe, closure.} =
      info "Hit subscribe response", message=msg

    var filters = newSeq[ContentFilter]()
    for topics in contentFilters:
      var contentTopics = newSeq[ContentTopic]()
      for topic in topics:
        contentTopics.add(ContentTopic(topic))
      filters.add(ContentFilter(topics: contentTopics))

    await node.subscribe(FilterRequest(topic: topic, contentFilters: filters, subscribe: true), handler)
    return true

  rpcsrv.rpc("waku_info") do() -> string:
    debug "waku_node_info"

    let wakuInfo = node.info()
    let listenStr = wakuInfo.listenStr
    info "Listening on", full = listenStr

    return listenStr
