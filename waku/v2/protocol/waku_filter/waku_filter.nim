{.push raises: [Defect].}

import
  std/[tables, sequtils, options],
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/pubsub/pubsubpeer,
  libp2p/protocols/pubsub/floodsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  waku_filter_types,
  ../../utils/requests,
  ../../node/peer_manager/peer_manager

# NOTE This is just a start, the design of this protocol isn't done yet. It
# should be direct payload exchange (a la req-resp), not be coupled with the
# relay protocol.

export waku_filter_types

declarePublicGauge waku_filter_peers, "number of filter peers"
declarePublicGauge waku_filter_subscribers, "number of light node filter subscribers"
declarePublicGauge waku_filter_errors, "number of filter protocol errors", ["type"]

logScope:
  topics = "wakufilter"

const
  WakuFilterCodec* = "/vac/waku/filter/2.0.0-beta1"
  WakuFilterTimeout: Duration = 1.days

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"

proc notify*(filters: Filters, msg: WakuMessage, requestId: string = "") {.raises: [Defect, KeyError]} =
  for key in filters.keys:
    let filter = filters[key]
    # We do this because the key for the filter is set to the requestId received from the filter protocol.
    # This means we do not need to check the content filter explicitly as all MessagePushs already contain
    # the requestId of the coresponding filter.
    if requestId != "" and requestId == key:
      filter.handler(msg)
      continue

    # TODO: In case of no topics we should either trigger here for all messages,
    # or we should not allow such filter to exist in the first place.
    for contentFilter in filter.contentFilters:
      if msg.contentTopic == contentFilter.contentTopic:
        filter.handler(msg)
        break

proc unsubscribeFilters(subscribers: var seq[Subscriber], request: FilterRequest, peerId: PeerID) =
  # Flatten all unsubscribe topics into single seq
  let unsubscribeTopics = request.contentFilters.mapIt(it.contentTopic)
  debug "unsubscribing", peerId=peerId, unsubscribeTopics=unsubscribeTopics

  for subscriber in subscribers.mitems:
    if subscriber.peer != peerId: continue
    
    # make sure we delete the content filter
    # if no more topics are left
    subscriber.filter.contentFilters.keepIf(proc (cf: auto): bool = cf.contentTopic notin unsubscribeTopics)

  # make sure we delete the subscriber
  # if no more content filters left
  subscribers.keepIf(proc (s: auto): bool = s.filter.contentFilters.len > 0)

  debug "subscribers modified", subscribers=subscribers
  # @TODO: metrics?

proc encode*(filter: ContentFilter): ProtoBuffer =
  var output = initProtoBuffer()

  output.write(1, filter.contentTopic)
  return output

proc encode*(rpc: FilterRequest): ProtoBuffer =
  var output = initProtoBuffer()
  
  output.write(1, uint64(rpc.subscribe))

  output.write(2, rpc.pubSubTopic)

  for filter in rpc.contentFilters:
    output.write(3, filter.encode())

  return output

proc init*(T: type ContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var contentTopic: ContentTopic
  discard ? pb.getField(1, contentTopic)

  return ok(ContentFilter(contentTopic: contentTopic))

proc init*(T: type FilterRequest, buffer: seq[byte]): ProtoResult[T] =
  var rpc = FilterRequest(contentFilters: @[], pubSubTopic: "")
  let pb = initProtoBuffer(buffer)

  var subflag: uint64
  if ? pb.getField(1, subflag):
    rpc.subscribe = bool(subflag)

  discard ? pb.getField(2, rpc.pubSubTopic)

  var buffs: seq[seq[byte]]
  discard ? pb.getRepeatedField(3, buffs)
  
  for buf in buffs:
    rpc.contentFilters.add(? ContentFilter.init(buf))

  return ok(rpc)

proc encode*(push: MessagePush): ProtoBuffer =
  var output = initProtoBuffer()

  for push in push.messages:
    output.write(1, push.encode())

  return output

proc init*(T: type MessagePush, buffer: seq[byte]): ProtoResult[T] =
  var push = MessagePush()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, messages)

  for buf in messages:
    push.messages.add(? WakuMessage.init(buf))

  return ok(push)

proc init*(T: type FilterRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = FilterRPC()
  let pb = initProtoBuffer(buffer) 

  discard ? pb.getField(1, rpc.requestId)

  var requestBuffer: seq[byte]
  discard ? pb.getField(2, requestBuffer)

  rpc.request = ? FilterRequest.init(requestBuffer)

  var pushBuffer: seq[byte]
  discard ? pb.getField(3, pushBuffer)

  rpc.push = ? MessagePush.init(pushBuffer)

  return ok(rpc)

proc encode*(rpc: FilterRPC): ProtoBuffer =
  var output = initProtoBuffer()

  output.write(1, rpc.requestId)
  output.write(2, rpc.request.encode())
  output.write(3, rpc.push.encode())

  return output

method init*(wf: WakuFilter) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = FilterRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    info "filter message received"

    let value = res.value
    if value.push != MessagePush():
      wf.pushHandler(value.requestId, value.push)
    if value.request != FilterRequest():
      if value.request.subscribe:
        wf.subscribers.add(Subscriber(peer: conn.peerId, requestId: value.requestId, filter: value.request))
      else:
        wf.subscribers.unsubscribeFilters(value.request, conn.peerId)
      
      waku_filter_subscribers.set(wf.subscribers.len.int64)

  wf.handler = handle
  wf.codec = WakuFilterCodec

proc init*(T: type WakuFilter, peerManager: PeerManager, rng: ref BrHmacDrbgContext, handler: MessagePushHandler,timeout: Duration = WakuFilterTimeout): T =
  let rng = crypto.newRng()
  var wf = WakuFilter(rng: rng,
                      peerManager: peerManager, 
                      pushHandler: handler,
                      timeout: timeout)
  wf.init()
  return wf

proc setPeer*(wf: WakuFilter, peer: RemotePeerInfo) =
  wf.peerManager.addPeer(peer, WakuFilterCodec)
  waku_filter_peers.inc()

#clear the failed peer table if subscriber was able to connect.
proc handleClientSuccess(wf: WakuFilter, subscribers: seq[Subscriber]){.raises: [Defect, KeyError].} = 
  for subscriber in subscribers:
    var subKey: string = $(subscriber)
    if wf.failedPeers.hasKey(subKey):
      wf.failedPeers.del(subKey)

# If we have already failed to send message to this peer,
# check for elapsed time and if it's been too long, remove the peer.
proc handleClientError(wf: WakuFilter, subscribers: seq[Subscriber]){.raises: [Defect, KeyError].} = 
  for subscriber in subscribers:
    var subKey: string = $(subscriber)
    if wf.failedPeers.hasKey(subKey):
      var elapsedTime = Moment.now() - wf.failedPeers[subKey]
      if(elapsedTime > wf.timeout):
        trace "Remove peer if timeout has reached for", peer=subscriber
        var index = wf.subscribers.find(subscriber)
        wf.subscribers.delete(index)
        wf.failedPeers.del(subKey)
    else:
      # add the peer to the failed peers table.
      wf.failedPeers[subKey] = Moment.now() 
  return

proc handleMessage*(wf: WakuFilter, topic: string, msg: WakuMessage) {.async.} =
  # Handle WakuMessage according to filter protocol
  trace "handle message in WakuFilter", topic=topic, msg=msg
  var handleMessageFailed = false
  var failedSubscriber: seq[Subscriber]
  var connectedSubscribers: seq[Subscriber]
  for subscriber in wf.subscribers:
    if subscriber.filter.pubSubTopic != "" and subscriber.filter.pubSubTopic != topic:
      trace "Subscriber's filter pubsubTopic does not match message topic", filter=subscriber.filter.pubSubTopic, topic=topic
      continue
    
    for filter in subscriber.filter.contentFilters:
      if msg.contentTopic == filter.contentTopic:
        trace "Found matching contentTopic", filter=filter, msg=msg
        let push = FilterRPC(requestId: subscriber.requestId, push: MessagePush(messages: @[msg]))
        let connOpt = await wf.peerManager.dialPeer(subscriber.peer, WakuFilterCodec)
        if connOpt.isSome:
          await connOpt.get().writeLP(push.encode().buffer)
          connectedSubscribers.add(subscriber)
        else:
          # @TODO more sophisticated error handling here
          handleMessageFailed = true
          failedSubscriber.add(subscriber)
          error "failed to push messages to remote peer"
          waku_filter_errors.inc(labelValues = [dialFailure])
        break
  handleClientSuccess(wf, connectedSubscribers)
  if handleMessageFailed:
    handleClientError(wf, failedSubscriber)

proc subscribe*(wf: WakuFilter, request: FilterRequest): Future[Option[string]] {.async, gcsafe.} =
  let peerOpt = wf.peerManager.selectPeer(WakuFilterCodec)

  if peerOpt.isSome:
    let peer = peerOpt.get()
    
    let connOpt = await wf.peerManager.dialPeer(peer, WakuFilterCodec)

    if connOpt.isSome:
      # This is the only successful path to subscription
      let id = generateRequestId(wf.rng)
      await connOpt.get().writeLP(FilterRPC(requestId: id, request: request).encode().buffer)
      return some(id)
    else:
      # @TODO more sophisticated error handling here
      error "failed to connect to remote peer"
      waku_filter_errors.inc(labelValues = [dialFailure])
      return none(string)

proc unsubscribe*(wf: WakuFilter, request: FilterRequest) {.async, gcsafe.} =
  # @TODO: NO REAL REASON TO GENERATE REQUEST ID FOR UNSUBSCRIBE OTHER THAN CREATING SANE-LOOKING RPC.
  let
    id = generateRequestId(wf.rng)
    peerOpt = wf.peerManager.selectPeer(WakuFilterCodec)

  if peerOpt.isSome:
    # @TODO: if there are more than one WakuFilter peer, WakuFilter should unsubscribe from all peers
    let peer = peerOpt.get()
    
    let connOpt = await wf.peerManager.dialPeer(peer, WakuFilterCodec)
    
    if connOpt.isSome:
      await connOpt.get().writeLP(FilterRPC(requestId: id, request: request).encode().buffer)
    else:
      # @TODO more sophisticated error handling here
      error "failed to connect to remote peer"
      waku_filter_errors.inc(labelValues = [dialFailure])
