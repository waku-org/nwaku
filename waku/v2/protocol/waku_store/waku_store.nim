## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md

import
  std/[tables, times, sequtils, algorithm, options],
  bearssl,
  chronos, chronicles, metrics, stew/[results, byteutils, endians2],
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ../message_notifier,
  ../../node/message_store/message_store,
  ../waku_swap/waku_swap,
  ./waku_store_types,
  ../../utils/requests

export waku_store_types

declarePublicGauge waku_store_messages, "number of historical messages"
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_store_errors, "number of store protocol errors", ["type"]

logScope:
  topics = "wakustore"

const
  WakuStoreCodec* = "/vac/waku/store/2.0.0-beta1"

# TODO Move serialization function to separate file, too noisy
# TODO Move pagination to separate file, self-contained logic

proc computeIndex*(msg: WakuMessage): Index =
  ## Takes a WakuMessage and returns its Index
  var ctx: sha256
  ctx.init()
  ctx.update(msg.contentTopic.toBytes()) # converts the contentTopic to bytes
  ctx.update(msg.payload)
  let digest = ctx.finish() # computes the hash
  ctx.clear()
  result.digest = digest
  result.receivedTime = epochTime() # gets the unix timestamp

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
    msg.messages.add(? WakuMessage.init(buf))

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

proc indexComparison* (x, y: Index): int =
  ## compares x and y
  ## returns 0 if they are equal 
  ## returns -1 if x < y
  ## returns 1 if x > y
  let 
    timecmp = system.cmp(x.receivedTime, y.receivedTime)
    digestcm = system.cmp(x.digest.data, y.digest.data)
  if timecmp != 0: # timestamp has a higher priority for comparison
    return timecmp
  return digestcm

proc indexedWakuMessageComparison*(x, y: IndexedWakuMessage): int =
  ## compares x and y
  ## returns 0 if they are equal 
  ## returns -1 if x < y
  ## returns 1 if x > y
  result = indexComparison(x.index, y.index)

proc findIndex*(msgList: seq[IndexedWakuMessage], index: Index): Option[int] =
  ## returns the position of an IndexedWakuMessage in msgList whose index value matches the given index
  ## returns none if no match is found
  for i, indexedWakuMessage in msgList:
    if indexedWakuMessage.index == index:
      return some(i)
  return none(int)

proc paginateWithIndex*(list: seq[IndexedWakuMessage], pinfo: PagingInfo): (seq[IndexedWakuMessage], PagingInfo) =
  ## takes list, and performs paging based on pinfo 
  ## returns the page i.e, a sequence of IndexedWakuMessage and the new paging info to be used for the next paging request
  var
    cursor = pinfo.cursor
    pageSize = pinfo.pageSize
    dir = pinfo.direction

  if pageSize == 0: # pageSize being zero indicates that no pagination is required
    return (list, pinfo)

  if list.len == 0: # no pagination is needed for an empty list
    return (list, PagingInfo(pageSize: 0, cursor:pinfo.cursor, direction: pinfo.direction))

  var msgList = list # makes a copy of the list
  # sorts msgList based on the custom comparison proc indexedWakuMessageComparison
  msgList.sort(indexedWakuMessageComparison) 

  var initQuery = false
  if cursor == Index(): 
    initQuery = true # an empty cursor means it is an intial query
    case dir
      of PagingDirection.FORWARD: 
        cursor = list[0].index # perform paging from the begining of the list
      of PagingDirection.BACKWARD: 
        cursor = list[list.len - 1].index # perform paging from the end of the list
  var foundIndexOption = msgList.findIndex(cursor) 
  if foundIndexOption.isNone: # the cursor is not valid
    return (@[], PagingInfo(pageSize: 0, cursor:pinfo.cursor, direction: pinfo.direction))
  var foundIndex = foundIndexOption.get()
  var retrievedPageSize, s, e: int
  var newCursor: Index # to be returned as part of the new paging info
  case dir
    of PagingDirection.FORWARD: # forward pagination
      let remainingMessages= msgList.len - foundIndex - 1
      # the number of queried messages cannot exceed the MaxPageSize and the total remaining messages i.e., msgList.len-foundIndex
      retrievedPageSize = min(int(pageSize), MaxPageSize).min(remainingMessages)  
      if initQuery : foundIndex = foundIndex - 1
      s = foundIndex + 1  # non inclusive
      e = foundIndex + retrievedPageSize 
      newCursor = msgList[e].index # the new cursor points to the end of the page
    of PagingDirection.BACKWARD: # backward pagination
      let remainingMessages=foundIndex
      # the number of queried messages cannot exceed the MaxPageSize and the total remaining messages i.e., foundIndex-0
      retrievedPageSize = min(int(pageSize), MaxPageSize).min(remainingMessages) 
      if initQuery : foundIndex = foundIndex + 1
      s = foundIndex - retrievedPageSize 
      e = foundIndex - 1
      newCursor = msgList[s].index # the new cursor points to the begining of the page

  # retrieve the messages
  for i in s..e:
    result[0].add(msgList[i])

  result[1] = PagingInfo(pageSize : uint64(retrievedPageSize), cursor : newCursor, direction : pinfo.direction)


proc paginateWithoutIndex(list: seq[IndexedWakuMessage], pinfo: PagingInfo): (seq[WakuMessage], PagingInfo) =
  ## takes list, and perfomrs paging based on pinfo 
  ## returns the page i.e, a sequence of WakuMessage and the new paging info to be used for the next paging request  
  var (indexedData, updatedPagingInfo) = paginateWithIndex(list,pinfo)
  for indexedMsg in indexedData:
    result[0].add(indexedMsg.msg)
  result[1] = updatedPagingInfo

proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResponse =
  result = HistoryResponse(messages: newSeq[WakuMessage]())
  # data holds IndexedWakuMessage whose topics match the query
  var data = w.messages.filterIt(it.msg.contentTopic in query.topics)  
  
  # perform pagination
  (result.messages, result.pagingInfo)= paginateWithoutIndex(data, query.pagingInfo)


method init*(ws: WakuStore) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = HistoryRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_store_errors.inc(labelValues = ["decode_rpc_failure"])
      return

    info "received query"

    let value = res.value
    let response = ws.findMessages(res.value.query)

    # TODO Do accounting here, response is HistoryResponse
    # How do we get node or swap context?
    if not ws.wakuSwap.isNil:
      info "handle store swap test", text=ws.wakuSwap.text
      # NOTE Perform accounting operation
      let peerId = conn.peerInfo.peerId
      let messages = response.messages
      ws.wakuSwap.credit(peerId, messages.len)
    else:
      info "handle store swap is nil"

    await conn.writeLp(HistoryRPC(requestId: value.requestId,
        response: response).encode().buffer)

  ws.handler = handle
  ws.codec = WakuStoreCodec

  if ws.store.isNil:
    return

  proc onData(timestamp: uint64, msg: WakuMessage) =
    ws.messages.add(IndexedWakuMessage(msg: msg, index: msg.computeIndex()))

  let res = ws.store.getAll(onData)
  if res.isErr:
    warn "failed to load messages from store", err = res.error
    waku_store_errors.inc(labelValues = ["store_load_failure"])
  
  waku_store_messages.set(ws.messages.len.int64, labelValues = ["stored"])

proc init*(T: type WakuStore, switch: Switch, rng: ref BrHmacDrbgContext,
                   store: MessageStore = nil, wakuSwap: WakuSwap = nil): T =
  new result
  result.rng = rng
  result.switch = switch
  result.store = store
  result.wakuSwap = wakuSwap
  result.init()

# @TODO THIS SHOULD PROBABLY BE AN ADD FUNCTION AND APPEND THE PEER TO AN ARRAY
proc setPeer*(ws: WakuStore, peer: PeerInfo) =
  ws.peers.add(HistoryPeer(peerInfo: peer))
  waku_store_peers.inc()

proc subscription*(proto: WakuStore): MessageNotificationSubscription =
  ## The filter function returns the pubsub filter for the node.
  ## This is used to pipe messages into the storage, therefore
  ## the filter should be used by the component that receives
  ## new messages.
  proc handle(topic: string, msg: WakuMessage) {.async.} =
    let index = msg.computeIndex()
    proto.messages.add(IndexedWakuMessage(msg: msg, index: index))
    waku_store_messages.inc(labelValues = ["stored"])
    if proto.store.isNil:
      return
  
    let res = proto.store.put(index, msg)
    if res.isErr:
      warn "failed to store messages", err = res.error
      waku_store_errors.inc(labelValues = ["store_failure"])

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

  await conn.writeLP(HistoryRPC(requestId: generateRequestId(w.rng),
      query: query).encode().buffer)

  var message = await conn.readLp(64*1024)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = ["decode_rpc_failure"])
    return

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])

  handler(response.value.response)

# NOTE: Experimental, maybe incorporate as part of query call
proc queryWithAccounting*(ws: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  # @TODO We need to be more stratigic about which peers we dial. Right now we just set one on the service.
  # Ideally depending on the query and our set  of peers we take a subset of ideal peers.
  # This will require us to check for various factors such as:
  #  - which topics they track
  #  - latency?
  #  - default store peer?

  let peer = ws.peers[0]
  let conn = await ws.switch.dial(peer.peerInfo.peerId, peer.peerInfo.addrs, WakuStoreCodec)

  await conn.writeLP(HistoryRPC(requestId: generateRequestId(ws.rng),
      query: query).encode().buffer)

  var message = await conn.readLp(64*1024)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = ["decode_rpc_failure"])
    return

  # NOTE Perform accounting operation
  # Assumes wakuSwap protocol is mounted
  let peerId = peer.peerInfo.peerId
  let messages = response.value.response.messages
  ws.wakuSwap.debit(peerId, messages.len)

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])

  handler(response.value.response)
