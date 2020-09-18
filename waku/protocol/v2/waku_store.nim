import
  std/tables,
  chronos, chronicles, metrics, stew/results,
  libp2p/switch,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ./message_notifier,
  ./../../node/v2/waku_types

logScope:
  topics = "wakustore"

const
  WakuStoreCodec* = "/vac/waku/store/2.0.0-alpha5"

proc init*(T: type HistoryQuery, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  var topics: seq[string]

  discard ? pb.getField(1, msg.uuid)
  discard ? pb.getRepeatedField(2, topics)

  msg.topics = topics
  ok(msg)

proc init*(T: type HistoryResponse, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryResponse()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]

  discard ? pb.getField(1, msg.uuid)
  discard ? pb.getRepeatedField(2, messages)

  for buf in messages:
    msg.messages.add(? WakuMessage.init(buf))

  ok(msg)

proc encode*(query: HistoryQuery): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, query.uuid)

  for topic in query.topics:
    result.write(2, topic)

proc encode*(response: HistoryResponse): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, response.uuid)

  for msg in response.messages:
    result.write(2, msg.encode())

proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResponse =
  result = HistoryResponse(uuid: query.uuid, messages: newSeq[WakuMessage]())
  for msg in w.messages:
    if msg.contentTopic in query.topics:
      result.messages.insert(msg)

method init*(ws: WakuStore) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var rpc = HistoryQuery.init(message)
    if rpc.isErr:
      return

    info "received query"

    let res = ws.findMessages(rpc.value)

    await conn.writeLp(res.encode().buffer)

  ws.handler = handle
  ws.codec = WakuStoreCodec

proc init*(T: type WakuStore, peer: PeerInfo, switch: Switch): T =
  new result
  result.peerInfo = peer
  result.switch = switch
  result.init()

proc subscription*(proto: WakuStore): MessageNotificationSubscription =
  ## The filter function returns the pubsub filter for the node.
  ## This is used to pipe messages into the storage, therefore
  ## the filter should be used by the component that receives
  ## new messages.
  proc handle(topic: string, msg: WakuMessage) {.async.} =
    proto.messages.add(msg)

  MessageNotificationSubscription.init(@[], handle)

proc query*(w: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  let conn = await w.switch.dial(w.peerInfo.peerId, w.peerInfo.addrs, WakuStoreCodec)

  await conn.writeLP(query.encode().buffer)

  var message = await conn.readLp(64*1024)
  let response = HistoryResponse.init(message)

  if response.isOk:
    handler(response.value)
