import
  std/tables,
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ./message_notifier,
  ./../../node/v2/waku_types

logScope:
  topics = "wakustore"

const
  WakuStoreCodec* = "/vac/waku/store/2.0.0-beta1"

proc encode*(index: Index): ProtoBuffer =
  ## encodes an Index object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  result = initProtoBuffer()

  # encodes index
  result.write(1, index.digest.data)
  result.write(2, index.receivedTime)

proc encode*(pd: PagingDirection): ProtoBuffer =
  ## encodes a PagingDirection into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  result = initProtoBuffer()

  # encodes pd
  result.write(1, uint32(ord(pd)))

proc encode*(pinfo: PagingInfo): ProtoBuffer =
  ## encodes a PagingInfo object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  result = initProtoBuffer()

  # encodes pinfo
  result.write(1, pinfo.pageSize)
  result.write(2, pinfo.cursor.encode())
  result.write(3, pinfo.direction.encode())

proc init*(T: type Index, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns an Index object out of buffer
  var index = Index()
  let pb = initProtoBuffer(buffer)

  var data: seq[byte]
  discard ? pb.getField(1, data)

  # create digest from data
  index.digest = MDigest[256]()
  for count, b in data:
    index.digest.data[count] = b

  # read the receivedTime
  var receivedTime: float64
  discard ? pb.getField(2, receivedTime)
  index.receivedTime = receivedTime

  ok(index) 

proc init*(T: type PagingDirection, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingDirection object out of buffer
  let pb = initProtoBuffer(buffer)

  var dir: uint32
  discard ? pb.getField(1, dir)
  var direction = PagingDirection(dir)

  ok(direction)

proc init*(T: type PagingInfo, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingInfo object out of buffer
  var pagingInfo = PagingInfo()
  let pb = initProtoBuffer(buffer)

  var pageSize: uint32
  discard ? pb.getField(1, pageSize)
  pagingInfo.pageSize = pageSize


  var cursorBuffer: seq[byte]
  discard ? pb.getField(2, cursorBuffer)
  pagingInfo.cursor = ? Index.init(cursorBuffer)

  var directionBuffer: seq[byte]
  discard ? pb.getField(3, directionBuffer)
  pagingInfo.direction = ? PagingDirection.init(directionBuffer)

  ok(pagingInfo) 
  
proc init*(T: type HistoryQuery, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  var topics: seq[ContentTopic]

  discard ? pb.getRepeatedField(1, topics)

  msg.topics = topics

  var pagingInfoBuffer: seq[byte]
  discard ? pb.getField(2, pagingInfoBuffer)

  msg.pagingInfo = ? PagingInfo.init(pagingInfoBuffer)

  ok(msg)

proc init*(T: type HistoryResponse, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryResponse()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, messages)

  for buf in messages:
    msg.messages.add( ? WakuMessage.init(buf))

  var pagingInfoBuffer: seq[byte]
  discard ? pb.getField(2,pagingInfoBuffer)
  msg.pagingInfo= ? PagingInfo.init(pagingInfoBuffer)

  ok(msg)

proc init*(T: type HistoryRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryRPC()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, rpc.requestId)

  var queryBuffer: seq[byte]
  discard ? pb.getField(2, queryBuffer)

  rpc.query = ? HistoryQuery.init(queryBuffer)

  var responseBuffer: seq[byte]
  discard ? pb.getField(3, responseBuffer)

  rpc.response = ? HistoryResponse.init(responseBuffer)

  ok(rpc)

proc encode*(query: HistoryQuery): ProtoBuffer =
  result = initProtoBuffer()

  for topic in query.topics:
    result.write(1, topic)
  
  result.write(2, query.pagingInfo.encode())

proc encode*(response: HistoryResponse): ProtoBuffer =
  result = initProtoBuffer()

  for msg in response.messages:
    result.write(1, msg.encode())

  result.write(2, response.pagingInfo.encode())

proc encode*(rpc: HistoryRPC): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, rpc.requestId)
  result.write(2, rpc.query.encode())
  result.write(3, rpc.response.encode())

proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResponse =
  result = HistoryResponse(messages: newSeq[WakuMessage]())
  for msg in w.messages:
    if msg.contentTopic in query.topics:
      result.messages.insert(msg)

method init*(ws: WakuStore) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = HistoryRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      return

    info "received query"

    let value = res.value
    let response = ws.findMessages(res.value.query)
    await conn.writeLp(HistoryRPC(requestId: value.requestId, response: response).encode().buffer)

  ws.handler = handle
  ws.codec = WakuStoreCodec

proc init*(T: type WakuStore, switch: Switch, rng: ref BrHmacDrbgContext): T =
  new result
  result.rng = rng
  result.switch = switch
  result.init()

# @TODO THIS SHOULD PROBABLY BE AN ADD FUNCTION AND APPEND THE PEER TO AN ARRAY
proc setPeer*(ws: WakuStore, peer: PeerInfo) =
  ws.peers.add(HistoryPeer(peerInfo: peer))

proc subscription*(proto: WakuStore): MessageNotificationSubscription =
  ## The filter function returns the pubsub filter for the node.
  ## This is used to pipe messages into the storage, therefore
  ## the filter should be used by the component that receives
  ## new messages.
  proc handle(topic: string, msg: WakuMessage) {.async.} =
    proto.messages.add(msg)

  MessageNotificationSubscription.init(@[], handle)

proc query*(w: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  # @TODO We need to be more stratigic about which peers we dial. Right now we just set one on the service.
  # Ideally depending on the query and our set  of peers we take a subset of ideal peers.
  # This will require us to check for various factors such as:
  #  - which topics they track
  #  - latency?
  #  - default store peer?

  let peer = w.peers[0]
  let conn = await w.switch.dial(peer.peerInfo.peerId, peer.peerInfo.addrs, WakuStoreCodec)

  await conn.writeLP(HistoryRPC(requestId: generateRequestId(w.rng), query: query).encode().buffer)

  var message = await conn.readLp(64*1024)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    return

  handler(response.value.response)
