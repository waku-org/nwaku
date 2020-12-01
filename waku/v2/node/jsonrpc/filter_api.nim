{.push raises: [Exception, Defect].}

import
  json_rpc/rpcserver,
  eth/[common, rlp, keys, p2p],
  ../../waku_types,
  ../wakunode2

proc installFilterApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  const futTimeout = 5.seconds

  ## Filter API version 1 definitions
  
  rpcsrv.rpc("post_waku_v2_filter_v1_subscription") do(contentFilters: seq[ContentFilter], topic: Option[string]) -> bool:
    ## Subscribes a node to a list of content filters
    debug "post_waku_v2_filter_v1_subscription"

    proc filterHandler(msg: WakuMessage) {.gcsafe, closure.} =
      debug "WakuMessage received", msg=msg, topic=topic
      # @TODO handle message

    # Construct a filter request
    # @TODO use default PubSub topic if undefined
    let fReq = if topic.isSome: FilterRequest(topic: topic.get, contentFilters: contentFilters, subscribe: true) else: FilterRequest(contentFilters: contentFilters, subscribe: true)
    
    if (await node.subscribe(fReq, filterHandler).withTimeout(futTimeout)):
      # Successfully subscribed to all content filters
      return true
    else:
      # Failed to subscribe to one or more content filters
      raise newException(ValueError, "Failed to subscribe to contentFilters " & repr(fReq))

  rpcsrv.rpc("delete_waku_v2_filter_v1_subscription") do(contentFilters: seq[ContentFilter], topic: Option[string]) -> bool:
    ## Unsubscribes a node from a list of content filters
    debug "delete_waku_v2_filter_v1_subscription"

    # Construct a filter request
    # @TODO consider using default PubSub topic if undefined
    let fReq = if topic.isSome: FilterRequest(topic: topic.get, contentFilters: contentFilters, subscribe: false) else: FilterRequest(contentFilters: contentFilters, subscribe: false)

    if (await node.unsubscribe(fReq).withTimeout(futTimeout)):
      # Successfully unsubscribed from all content filters
      return true
    else:
      # Failed to unsubscribe from one or more content filters
      raise newException(ValueError, "Failed to unsubscribe from contentFilters " & repr(fReq))