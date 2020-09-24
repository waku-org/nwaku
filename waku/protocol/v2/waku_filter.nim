import
  std/tables,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/pubsub/pubsubpeer,
  libp2p/protocols/pubsub/floodsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  libp2p/switch,
  ./message_notifier,
  ./../../node/v2/waku_types

# NOTE This is just a start, the design of this protocol isn't done yet. It
# should be direct payload exchange (a la req-resp), not be coupled with the
# relay protocol.

logScope:
  topics = "wakufilter"

const
  WakuFilterCodec* = "/vac/waku/filter/2.0.0-alpha6"

proc encode*(filter: ContentFilter): ProtoBuffer =
  result = initProtoBuffer()

  for topic in filter.topics:
    result.write(1, topic)

proc encode*(rpc: FilterRequest): ProtoBuffer =
  result = initProtoBuffer()

  for filter in rpc.contentFilter:
    result.write(1, filter.encode())

  result.write(2, rpc.topic)

proc init*(T: type ContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var topics: seq[string]
  discard ? pb.getRepeatedField(1, topics)

  ok(ContentFilter(topics: topics))

proc init*(T: type FilterRequest, buffer: seq[byte]): ProtoResult[T] =
  var rpc = FilterRequest(contentFilter: @[], topic: "")
  let pb = initProtoBuffer(buffer)

  var buffs: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, buffs)
  
  for buf in buffs:
    rpc.contentFilter.add(? ContentFilter.init(buf))

  discard ? pb.getField(2, rpc.topic)

  ok(rpc)

proc encode*(push: MessagePush): ProtoBuffer =
  result = initProtoBuffer()

  for push in push.messages:
    result.write(1, push.encode())

proc init*(T: type MessagePush, buffer: seq[byte]): ProtoResult[T] =
  var push = MessagePush()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, messages)

  for buf in messages:
    push.messages.add(? WakuMessage.init(buf))

  ok(push)

proc init*(T: type FilterRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = FilterRPC()
  let pb = initProtoBuffer(buffer) 

  var requestBuffer: seq[byte]
  discard ? pb.getField(1, requestBuffer)

  rpc.request = ? FilterRequest.init(requestBuffer)

  var pushBuffer: seq[byte]
  discard ? pb.getField(2, pushBuffer)

  rpc.push = ? MessagePush.init(pushBuffer)

  ok(rpc)

proc encode*(rpc: FilterRPC): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, rpc.request.encode())
  result.write(2, rpc.push.encode())

method init*(wf: WakuFilter) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = FilterRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      return

    let value = res.value
    if value.push != MessagePush():
      await wf.pushHandler(value.push)
    if value.request != FilterRequest():
      wf.subscribers.add(Subscriber(peer: conn.peerInfo, requestId: value.requestId, filter: value.request))

  wf.handler = handle
  wf.codec = WakuFilterCodec

proc init*(T: type WakuFilter, switch: Switch, handler: MessagePushHandler): T =
  new result
  result.switch = switch
  result.pushHandler = handler
  result.init()

proc subscription*(proto: WakuFilter): MessageNotificationSubscription =
  ## Returns a Filter for the specific protocol
  ## This filter can then be used to send messages to subscribers that match conditions.   
  proc handle(topic: string, msg: WakuMessage) {.async.} =
    for subscriber in proto.subscribers:
      if subscriber.filter.topic != topic:
        continue

      for filter in subscriber.filter.contentFilter:
        if msg.contentTopic in filter.topics:
          let push = FilterRPC(requestId: subscriber.requestId, push: MessagePush(messages: @[msg]))
          let conn = await proto.switch.dial(subscriber.peer.peerId, subscriber.peer.addrs, WakuFilterCodec)
          await conn.writeLP(push.encode().buffer)
          break

  MessageNotificationSubscription.init(@[], handle)

proc subscribe*(wf: WakuFilter, peer: PeerInfo, request: FilterRequest) {.async, gcsafe.} =
  let conn = await wf.switch.dial(peer.peerId, peer.addrs, WakuFilterCodec)
  await conn.writeLP(FilterRPC(requestId: generateRequestId(), request: request).encode().buffer)
