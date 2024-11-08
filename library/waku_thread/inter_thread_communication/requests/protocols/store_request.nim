import std/[json, sugar, strutils, options]
import chronos, chronicles, results
import
  ../../../../../waku/factory/waku,
  ../../../../alloc,
  ../../../../../waku/waku_core/peers,
  ../../../../../waku/waku_core/time,
  ../../../../../waku/waku_core/message/digest,
  ../../../../../waku/waku_store/common,
  ../../../../../waku/waku_store/client,
  ../../../../../waku/common/paging

type StoreReqType* = enum
  REMOTE_QUERY ## to perform a query to another Store node

type JsonStoreQueryRequest* = object
  jsonQuery: cstring
  peerAddr: cstring
  timeoutMs: cint

type StoreRequest* = object
  operation: StoreReqType
  storeReq: pointer

func fromJsonNode(
    T: type JsonStoreQueryRequest, jsonContent: JsonNode
): StoreQueryRequest =
  let contentTopics = collect(newSeq):
    for cTopic in jsonContent["content_topics"].getElems():
      cTopic.getStr()

  let msgHashes = collect(newSeq):
    for hashJsonObj in jsonContent["message_hashes"].getElems():
      var hash: WakuMessageHash
      var count: int = 0
      for byteValue in hashJsonObj.getElems():
        hash[count] = byteValue.getInt().byte
        count.inc()

      hash

  let pubsubTopic =
    if jsonContent.contains("pubsub_topic"):
      some(jsonContent["pubsub_topic"].getStr())
    else:
      none(string)

  let startTime =
    if jsonContent.contains("time_start"):
      some(Timestamp(jsonContent["time_start"].getInt()))
    else:
      none(Timestamp)

  let endTime =
    if jsonContent.contains("time_end"):
      some(Timestamp(jsonContent["time_end"].getInt()))
    else:
      none(Timestamp)

  let paginationCursor =
    if jsonContent.contains("pagination_cursor"):
      var hash: WakuMessageHash
      var count: int = 0
      for byteValue in jsonContent["pagination_cursor"].getElems():
        hash[count] = byteValue.getInt().byte
        count.inc()

      some(hash)
    else:
      none(WakuMessageHash)

  let paginationForwardBool = jsonContent["pagination_forward"].getBool()
  let paginationForward =
    if paginationForwardBool: PagingDirection.FORWARD else: PagingDirection.BACKWARD

  let paginationLimit =
    if jsonContent.contains("pagination_limit"):
      some(uint64(jsonContent["pagination_limit"].getInt()))
    else:
      none(uint64)

  return StoreQueryRequest(
    requestId: jsonContent["request_id"].getStr(),
    includeData: jsonContent["include_data"].getBool(),
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics,
    startTime: startTime,
    endTime: endTime,
    messageHashes: msgHashes,
    paginationCursor: paginationCursor,
    paginationForward: paginationForward,
    paginationLimit: paginationLimit,
  )

proc createShared*(
    T: type JsonStoreQueryRequest,
    jsonQuery: cstring,
    peerAddr: cstring,
    timeoutMs: cint,
): ptr type T =
  var ret = createShared(T)
  ret[].timeoutMs = timeoutMs
  ret[].jsonQuery = jsonQuery.alloc()
  ret[].peerAddr = peerAddr.alloc()
  return ret

proc destroyShared(self: ptr JsonStoreQueryRequest) =
  deallocShared(self[].jsonQuery)
  deallocShared(self[].peerAddr)
  deallocShared(self)

proc process(
    self: ptr JsonStoreQueryRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  let jsonContentRes = catch:
    parseJson($self[].jsonQuery)

  if jsonContentRes.isErr():
    return err(
      "JsonStoreQueryRequest failed parsing store request: " & jsonContentRes.error.msg
    )

  let storeQueryRequest = JsonStoreQueryRequest.fromJsonNode(jsonContentRes.get())

  let peer = peers.parsePeerInfo(($self[].peerAddr).split(",")).valueOr:
    return err("JsonStoreQueryRequest failed to parse peer addr: " & $error)

  let queryResponse = (await waku.node.wakuStoreClient.query(storeQueryRequest, peer)).valueOr:
    return err("JsonStoreQueryRequest failed store query: " & $error)

  return ok($(%*queryResponse)) ## returning the response in json format

proc process*(
    self: ptr StoreRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    deallocShared(self)

  case self.operation
  of REMOTE_QUERY:
    return await cast[ptr JsonStoreQueryRequest](self[].storeReq).process(waku)

  error "store request not handled at all"
  return err("store request not handled at all")
