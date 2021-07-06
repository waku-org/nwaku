## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md

{.push raises: [Defect].}

import
  std/[tables, times, sequtils, algorithm, options],
  bearssl,
  chronos, chronicles, metrics, stew/[results, byteutils, endians2],
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ../message_notifier,
  ../../node/storage/message/message_store,
  ../waku_swap/waku_swap,
  ./waku_store_types,
  ../../utils/requests,
  ../../node/peer_manager/peer_manager

export waku_store_types

declarePublicGauge waku_store_messages, "number of historical messages", ["type"]
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_store_errors, "number of store protocol errors", ["type"]

logScope:
  topics = "wakustore"

const
  WakuStoreCodec* = "/vac/waku/store/2.0.0-beta3"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"

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
  var index = Index(digest:digest, receiverTime: epochTime(), senderTime: msg.timestamp)
  return index

proc encode*(index: Index): ProtoBuffer =
  ## encodes an Index object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  result = initProtoBuffer()

  # encodes index
  result.write(1, index.digest.data)
  result.write(2, index.receiverTime)
  result.write(3, index.senderTime)

proc encode*(pinfo: PagingInfo): ProtoBuffer =
  ## encodes a PagingInfo object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  # intiate a ProtoBuffer
  result = initProtoBuffer()

  # encodes pinfo
  result.write(1, pinfo.pageSize)
  result.write(2, pinfo.cursor.encode())
  result.write(3, uint32(ord(pinfo.direction)))

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

  # read the timestamp
  var receiverTime: float64
  discard ? pb.getField(2, receiverTime)
  index.receiverTime = receiverTime

  # read the timestamp
  var senderTime: float64
  discard ? pb.getField(3, senderTime)
  index.senderTime = senderTime

  ok(index) 

proc init*(T: type PagingInfo, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingInfo object out of buffer
  var pagingInfo = PagingInfo()
  let pb = initProtoBuffer(buffer)

  var pageSize: uint64
  discard ? pb.getField(1, pageSize)
  pagingInfo.pageSize = pageSize


  var cursorBuffer: seq[byte]
  discard ? pb.getField(2, cursorBuffer)
  pagingInfo.cursor = ? Index.init(cursorBuffer)

  var direction: uint32
  discard ? pb.getField(3, direction)
  pagingInfo.direction = PagingDirection(direction)

  ok(pagingInfo) 

proc init*(T: type HistoryContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  # ContentTopic corresponds to the contentTopic field of waku message (not to be confused with pubsub topic)
  var contentTopic: ContentTopic
  discard ? pb.getField(1, contentTopic)

  ok(HistoryContentFilter(contentTopic: contentTopic))

proc init*(T: type HistoryQuery, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(2, msg.pubsubTopic)

  var buffs: seq[seq[byte]]
  discard ? pb.getRepeatedField(3, buffs)
  
  for buf in buffs:
    msg.contentFilters.add(? HistoryContentFilter.init(buf))

  var pagingInfoBuffer: seq[byte]
  discard ? pb.getField(4, pagingInfoBuffer)

  msg.pagingInfo = ? PagingInfo.init(pagingInfoBuffer)

  discard ? pb.getField(5, msg.startTime)
  discard ? pb.getField(6, msg.endTime)


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

proc encode*(filter: HistoryContentFilter): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, filter.contentTopic)

proc encode*(query: HistoryQuery): ProtoBuffer =
  result = initProtoBuffer()
  
  result.write(2, query.pubsubTopic)

  for filter in query.contentFilters:
    result.write(3, filter.encode())

  result.write(4, query.pagingInfo.encode())

  result.write(5, query.startTime)
  result.write(6, query.endTime)


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
    timecmp = system.cmp(x.senderTime, y.senderTime)
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

  if pageSize == uint64(0): # pageSize being zero indicates that no pagination is required
    return (list, pinfo)

  if list.len == 0: # no pagination is needed for an empty list
    return (list, PagingInfo(pageSize: 0, cursor:pinfo.cursor, direction: pinfo.direction))

  var msgList = list # makes a copy of the list
  # sorts msgList based on the custom comparison proc indexedWakuMessageComparison
  msgList.sort(indexedWakuMessageComparison) 
  
  var initQuery = false
  if cursor == Index(): 
    initQuery = true # an empty cursor means it is an initial query
    case dir
      of PagingDirection.FORWARD: 
        cursor = msgList[0].index # perform paging from the begining of the list
      of PagingDirection.BACKWARD: 
        cursor = msgList[list.len - 1].index # perform paging from the end of the list
  var foundIndexOption = msgList.findIndex(cursor) 
  if foundIndexOption.isNone: # the cursor is not valid
    return (@[], PagingInfo(pageSize: 0, cursor:pinfo.cursor, direction: pinfo.direction))
  var foundIndex = uint64(foundIndexOption.get())
  var retrievedPageSize, s, e: uint64
  var newCursor: Index # to be returned as part of the new paging info
  case dir
    of PagingDirection.FORWARD: # forward pagination
      # the message that is pointed by the cursor is excluded for the retrieved list, this is because this message has already been retrieved by the querier in its prior request
      var remainingMessages= uint64(msgList.len) - uint64(foundIndex) - 1 
      if initQuery:  remainingMessages = remainingMessages + 1
      # the number of queried messages cannot exceed the MaxPageSize and the total remaining messages i.e., msgList.len-foundIndex
      retrievedPageSize = min(uint64(pageSize), MaxPageSize).min(remainingMessages)  
      if initQuery : foundIndex = foundIndex - 1
      s = foundIndex + 1  # non inclusive
      e = foundIndex + retrievedPageSize 
      newCursor = msgList[e].index # the new cursor points to the end of the page
    of PagingDirection.BACKWARD: # backward pagination
      var remainingMessages = foundIndex 
      if initQuery:  remainingMessages = remainingMessages + 1
      # the number of queried messages cannot exceed the MaxPageSize and the total remaining messages i.e., foundIndex-0
      retrievedPageSize = min(uint64(pageSize), MaxPageSize).min(remainingMessages) 
      if initQuery : foundIndex = foundIndex + 1
      s = foundIndex - retrievedPageSize 
      e = foundIndex - 1
      newCursor = msgList[s].index # the new cursor points to the begining of the page

  if (retrievedPageSize == 0):
    return (@[], PagingInfo(pageSize: 0, cursor:pinfo.cursor, direction: pinfo.direction))

  # retrieve the messages
  for i in s..e:
    result[0].add(msgList[i])
  result[1] = PagingInfo(pageSize : retrievedPageSize, cursor : newCursor, direction : pinfo.direction)

proc paginateWithoutIndex(list: seq[IndexedWakuMessage], pinfo: PagingInfo): (seq[WakuMessage], PagingInfo) =
  ## takes list, and perfomrs paging based on pinfo 
  ## returns the page i.e, a sequence of WakuMessage and the new paging info to be used for the next paging request  
  var (indexedData, updatedPagingInfo) = paginateWithIndex(list,pinfo)
  for indexedMsg in indexedData:
    result[0].add(indexedMsg.msg)
  result[1] = updatedPagingInfo

proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResponse =
  result = HistoryResponse(messages: newSeq[WakuMessage]())
  var data : seq[IndexedWakuMessage] = w.messages

  # filter based on content filters
  # an empty list of contentFilters means no content filter is requested
  if ((query.contentFilters).len != 0):
    # matchedMessages holds IndexedWakuMessage whose content topics match the queried Content filters
    var matchedMessages : seq[IndexedWakuMessage] = @[]
    for filter in query.contentFilters:
      var matched = w.messages.filterIt(it.msg.contentTopic  == filter.contentTopic)  
      matchedMessages.add(matched)
    # remove duplicates 
    # duplicates may exist if two content filters target the same content topic, then the matched message gets added more than once
    data = matchedMessages.deduplicate()

  # filter based on pubsub topic
  # an empty pubsub topic means no pubsub topic filter is requested
  if ((query.pubsubTopic).len != 0):
    data = data.filterIt(it.pubsubTopic == query.pubsubTopic)

  # temporal filtering   
  # check whether the history query contains a time filter
  if (query.endTime != float64(0) and query.startTime != float64(0)):
    # for a valid time query, select messages whose sender generated timestamps fall bw the queried start time and end time
    data = data.filterIt(it.msg.timestamp <= query.endTime and it.msg.timestamp >= query.startTime)

  
  # perform pagination
  (result.messages, result.pagingInfo)= paginateWithoutIndex(data, query.pagingInfo)


proc init*(ws: WakuStore) {.raises: [Defect, Exception]} =
  proc handler(conn: Connection, proto: string) {.async.} =
    var message = await conn.readLp(64*1024)
    var res = HistoryRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_store_errors.inc(labelValues = [decodeRpcFailure])
      return

    # TODO Print more info here
    info "received query"

    let value = res.value
    let response = ws.findMessages(res.value.query)

    # TODO Do accounting here, response is HistoryResponse
    # How do we get node or swap context?
    if not ws.wakuSwap.isNil:
      info "handle store swap test", text=ws.wakuSwap.text
      # NOTE Perform accounting operation
      let peerInfo = conn.peerInfo
      let messages = response.messages
      ws.wakuSwap.credit(peerInfo, messages.len)
    else:
      info "handle store swap is nil"

    info "sending response", messages=response.messages.len

    await conn.writeLp(HistoryRPC(requestId: value.requestId,
        response: response).encode().buffer)

  ws.handler = handler
  ws.codec = WakuStoreCodec

  if ws.store.isNil:
    return

  proc onData(receiverTime: float64, msg: WakuMessage, pubsubTopic:  string) =
    # TODO index should not be recalculated
    ws.messages.add(IndexedWakuMessage(msg: msg, index: msg.computeIndex(), pubsubTopic: pubsubTopic))

  let res = ws.store.getAll(onData)
  if res.isErr:
    warn "failed to load messages from store", err = res.error
    waku_store_errors.inc(labelValues = ["store_load_failure"])
  
  debug "the number of messages in the memory", messageNum=ws.messages.len
  waku_store_messages.set(ws.messages.len.int64, labelValues = ["stored"])


proc init*(T: type WakuStore, peerManager: PeerManager, rng: ref BrHmacDrbgContext,
                   store: MessageStore = nil, wakuSwap: WakuSwap = nil): T {.raises: [Defect, Exception]} =
  debug "init"
  new result
  result.rng = rng
  result.peerManager = peerManager
  result.store = store
  result.wakuSwap = wakuSwap
  result.init()

# @TODO THIS SHOULD PROBABLY BE AN ADD FUNCTION AND APPEND THE PEER TO AN ARRAY
proc setPeer*(ws: WakuStore, peer: PeerInfo) {.raises: [Defect, Exception]} =
  ws.peerManager.addPeer(peer, WakuStoreCodec)
  waku_store_peers.inc()

proc subscription*(proto: WakuStore): MessageNotificationSubscription =
  ## The filter function returns the pubsub filter for the node.
  ## This is used to pipe messages into the storage, therefore
  ## the filter should be used by the component that receives
  ## new messages.
  proc handle(topic: string, msg: WakuMessage) {.async.} =
    debug "subscription handle", topic=topic
    let index = msg.computeIndex()
    proto.messages.add(IndexedWakuMessage(msg: msg, index: index, pubsubTopic: topic))
    waku_store_messages.inc(labelValues = ["stored"])
    if proto.store.isNil:
      return
  
    let res = proto.store.put(index, msg, topic)
    if res.isErr:
      warn "failed to store messages", err = res.error
      waku_store_errors.inc(labelValues = ["store_failure"])

  result = MessageNotificationSubscription.init(@[], handle)

proc query*(w: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  # @TODO We need to be more stratigic about which peers we dial. Right now we just set one on the service.
  # Ideally depending on the query and our set  of peers we take a subset of ideal peers.
  # This will require us to check for various factors such as:
  #  - which topics they track
  #  - latency?
  #  - default store peer?

  let peerOpt = w.peerManager.selectPeer(WakuStoreCodec)

  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  let connOpt = await w.peerManager.dialPeer(peerOpt.get(), WakuStoreCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  await connOpt.get().writeLP(HistoryRPC(requestId: generateRequestId(w.rng),
      query: query).encode().buffer)

  var message = await connOpt.get().readLp(64*1024)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])
  handler(response.value.response)

proc queryFrom*(w: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc, peer: PeerInfo): Future[QueryResult] {.async, gcsafe.} =
  ## sends the query to the given peer
  ## returns the number of retrieved messages if no error occurs, otherwise returns the error string
  # TODO dialPeer add it to the list of known peers, while it does not cause any issue but might be unnecessary
  let connOpt = await w.peerManager.dialPeer(peer, WakuStoreCodec)

  if connOpt.isNone():
    error "failed to connect to remote peer"
    waku_store_errors.inc(labelValues = [dialFailure])
    return err("failed to connect to remote peer")

  await connOpt.get().writeLP(HistoryRPC(requestId: generateRequestId(w.rng),
      query: query).encode().buffer)
  debug "query is sent", query=query
  var message = await connOpt.get().readLp(64*1024)
  let response = HistoryRPC.init(message)

  debug "response is received"

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return err("failed to decode response")
    

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])
  handler(response.value.response)
  return ok(response.value.response.messages.len.uint64)

proc queryFromWithPaging*(w: WakuStore, query: HistoryQuery, peer: PeerInfo): Future[MessagesResult] {.async, gcsafe.} =
  ## a thin wrapper for queryFrom
  ## sends the query to the given peer
  ## when the query has a valid pagingInfo, it retrieves the historical messages in pages
  ## returns all the fetched messages if no error occurs, otherwise returns an error string
  debug "queryFromWithPaging is called"
  var messageList: seq[WakuMessage]
  # make a copy of the query
  var q = query
  debug "query is", q=q

  var hasNextPage = true
  proc handler(response: HistoryResponse) {.gcsafe, raises: [Defect, Exception].} =
    # store messages
    for m in response.messages.items: messageList.add(m)
    
    # check whether it is the last page
    hasNextPage = (response.pagingInfo.pageSize != 0)
    debug "hasNextPage", hasNextPage=hasNextPage

    # update paging cursor
    q.pagingInfo.cursor = response.pagingInfo.cursor
    debug "next paging info", pagingInfo=q.pagingInfo

  # fetch the history in pages
  while (hasNextPage):
    let successResult = await w.queryFrom(q, handler, peer)
    if not successResult.isOk: return err("failed to resolve the query")
    debug "hasNextPage", hasNextPage=hasNextPage

  return ok(messageList)

proc queryLoop(w: WakuStore, query: HistoryQuery, candidateList: seq[PeerInfo]): Future[MessagesResult]  {.async, gcsafe.} = 
  ## loops through the candidateList in order and sends the query to each until one of the query gets resolved successfully
  ## returns the retrieved messages, or error if all the requests fail
  for peer in candidateList.items: 
    let successResult = await w.queryFromWithPaging(query, peer)
    if successResult.isOk: return ok(successResult.value)

  debug "failed to resolve the query"
  return err("failed to resolve the query")

proc findLastSeen*(list: seq[IndexedWakuMessage]): float = 
  var lastSeenTime = float64(0)
  for iwmsg in list.items : 
    if iwmsg.msg.timestamp>lastSeenTime: 
      lastSeenTime = iwmsg.msg.timestamp 
  return lastSeenTime

proc isDuplicate(message: WakuMessage, list: seq[WakuMessage]): bool =
  ## return true if a duplicate message is found, otherwise false
  # it is defined as a separate proc to be bale to adjust comparison criteria 
  # e.g., to exclude timestamp or include pubsub topic
  if message in list: return true
  return false

proc resume*(ws: WakuStore, peerList: Option[seq[PeerInfo]] = none(seq[PeerInfo]), pageSize: uint64 = DefaultPageSize): Future[QueryResult] {.async, gcsafe.} =
  ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku store node has been online 
  ## messages are stored in the store node's messages field and in the message db
  ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message 
  ## an offset of 20 second is added to the time window to count for nodes asynchrony
  ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
  ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from. 
  ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
  ## the resume proc returns the number of retrieved messages if no error occurs, otherwise returns the error string
  
  var currentTime = epochTime()
  var lastSeenTime: float = findLastSeen(ws.messages)
  debug "resume", currentEpochTime=currentTime
  
  # adjust the time window with an offset of 20 seconds
  let offset: float64 = 200000
  currentTime = currentTime + offset
  lastSeenTime = max(lastSeenTime - offset, 0)
  debug "the  offline time window is", lastSeenTime=lastSeenTime, currentTime=currentTime

  let 
    pinfo = PagingInfo(direction:PagingDirection.FORWARD, pageSize: pageSize)
    rpc = HistoryQuery(pubsubTopic: DefaultTopic, startTime: lastSeenTime, endTime: currentTime, pagingInfo: pinfo)


  var dismissed: uint = 0
  var added: uint = 0
  proc save(msgList: seq[WakuMessage]) {.raises: [Defect, Exception].} =
    debug "save proc is called"
    # exclude index from the comparison criteria
    let currentMsgSummary = ws.messages.map(proc(x: IndexedWakuMessage): WakuMessage = x.msg)
    for msg in msgList:
      # check for duplicate messages
      # TODO Should take pubsub topic into account if we are going to support topics rather than the DefaultTopic
      if isDuplicate(msg,currentMsgSummary): 
        dismissed = dismissed + 1
        continue

      # store the new message 
      let index = msg.computeIndex()
      let indexedWakuMsg = IndexedWakuMessage(msg: msg, index: index, pubsubTopic: DefaultTopic)
      
      # store in db if exists
      if not ws.store.isNil: 
        let res = ws.store.put(index, msg, DefaultTopic)
        if res.isErr:
          warn "failed to store messages", err = res.error
          waku_store_errors.inc(labelValues = ["store_failure"])
          continue
        
      ws.messages.add(indexedWakuMsg)
      waku_store_messages.inc(labelValues = ["stored"])
      
      added = added + 1

    debug "number of duplicate messages found in resume", dismissed=dismissed
    debug "number of messages added via resume", added=added

  if peerList.isSome:
    debug "trying the candidate list to fetch the history"
    let successResult = await ws.queryLoop(rpc, peerList.get())
    if successResult.isErr:
      debug "failed to resume the history from the list of candidates"
      return err("failed to resume the history from the list of candidates")
    debug "resume is done successfully"
    save(successResult.value)
    return ok(added)
  else:
    debug "no candidate list is provided, selecting a random peer"
    # if no peerList is set then query from one of the peers stored in the peer manager 
    let peerOpt = ws.peerManager.selectPeer(WakuStoreCodec)
    if peerOpt.isNone():
      error "no suitable remote peers"
      waku_store_errors.inc(labelValues = [dialFailure])
      return err("no suitable remote peers")

    debug "a peer is selected from peer manager"
    let peerInfo = peerOpt.get()
    let successResult = await ws.queryFromWithPaging(rpc, peerInfo)
    if successResult.isErr: 
      debug "failed to resume the history"
      return err("failed to resume the history")
    debug "resume is done successfully"
    save(successResult.value)
    return ok(added)

# NOTE: Experimental, maybe incorporate as part of query call
proc queryWithAccounting*(ws: WakuStore, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  # @TODO We need to be more stratigic about which peers we dial. Right now we just set one on the service.
  # Ideally depending on the query and our set  of peers we take a subset of ideal peers.
  # This will require us to check for various factors such as:
  #  - which topics they track
  #  - latency?
  #  - default store peer?

  let peerOpt = ws.peerManager.selectPeer(WakuStoreCodec)

  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  let connOpt = await ws.peerManager.dialPeer(peerOpt.get(), WakuStoreCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_store_errors.inc(labelValues = [dialFailure])
    return

  await connOpt.get().writeLP(HistoryRPC(requestId: generateRequestId(ws.rng),
      query: query).encode().buffer)

  var message = await connOpt.get().readLp(64*1024)
  let response = HistoryRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_store_errors.inc(labelValues = [decodeRpcFailure])
    return

  # NOTE Perform accounting operation
  # Assumes wakuSwap protocol is mounted
  let peerInfo = peerOpt.get()
  let messages = response.value.response.messages
  ws.wakuSwap.debit(peerInfo, messages.len)

  waku_store_messages.set(response.value.response.messages.len.int64, labelValues = ["retrieved"])

  handler(response.value.response)
