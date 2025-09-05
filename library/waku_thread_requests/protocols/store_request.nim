import std/[json, sugar, strutils, options]
import chronos, chronicles, results, stew/byteutils, ffi
import
  ../../../waku/factory/waku,
  ../../utils,
  ../../../waku/waku_core/peers,
  ../../../waku/waku_core/time,
  ../../../waku/waku_core/message/digest,
  ../../../waku/waku_store/common,
  ../../../waku/waku_store/client,
  ../../../waku/common/paging

type StoreReqType* = enum
  REMOTE_QUERY ## to perform a query to another Store node

type StoreRequest* = object
  operation: StoreReqType
  jsonQuery: cstring
  peerAddr: cstring
  timeoutMs: cint

func fromJsonNode(
    T: type StoreRequest, jsonContent: JsonNode
): Result[StoreQueryRequest, string] =
  var contentTopics: seq[string]
  if jsonContent.contains("contentTopics"):
    contentTopics = collect(newSeq):
      for cTopic in jsonContent["contentTopics"].getElems():
        cTopic.getStr()

  var msgHashes: seq[WakuMessageHash]
  if jsonContent.contains("messageHashes"):
    for hashJsonObj in jsonContent["messageHashes"].getElems():
      let hash = hashJsonObj.getStr().hexToHash().valueOr:
          return err("Failed converting message hash hex string to bytes: " & error)
      msgHashes.add(hash)

  let pubsubTopic =
    if jsonContent.contains("pubsubTopic"):
      some(jsonContent["pubsubTopic"].getStr())
    else:
      none(string)

  let paginationCursor =
    if jsonContent.contains("paginationCursor"):
      let hash = jsonContent["paginationCursor"].getStr().hexToHash().valueOr:
          return err("Failed converting paginationCursor hex string to bytes: " & error)
      some(hash)
    else:
      none(WakuMessageHash)

  let paginationForwardBool = jsonContent["paginationForward"].getBool()
  let paginationForward =
    if paginationForwardBool: PagingDirection.FORWARD else: PagingDirection.BACKWARD

  let paginationLimit =
    if jsonContent.contains("paginationLimit"):
      some(uint64(jsonContent["paginationLimit"].getInt()))
    else:
      none(uint64)

  let startTime = ?jsonContent.getProtoInt64("timeStart")
  let endTime = ?jsonContent.getProtoInt64("timeEnd")

  return ok(
    StoreQueryRequest(
      requestId: jsonContent["requestId"].getStr(),
      includeData: jsonContent["includeData"].getBool(),
      pubsubTopic: pubsubTopic,
      contentTopics: contentTopics,
      startTime: startTime,
      endTime: endTime,
      messageHashes: msgHashes,
      paginationCursor: paginationCursor,
      paginationForward: paginationForward,
      paginationLimit: paginationLimit,
    )
  )

registerReqFFI(StoreQueryReq, waku: ptr Waku):
  proc(
      jsonQuery: cstring, peerAddr: cstring, timeoutMs: cint
  ): Future[Result[string, string]] {.async.} =
    let jsonContentRes = catch:
      parseJson($jsonQuery)

    if jsonContentRes.isErr():
      return
        err("StoreRequest failed parsing store request: " & jsonContentRes.error.msg)

    let storeQueryRequest = ?StoreRequest.fromJsonNode(jsonContentRes.get())

    let peer = peers.parsePeerInfo(($peerAddr).split(",")).valueOr:
      return err("StoreRequest failed to parse peer addr: " & $error)

    let queryResponse = (await waku.node.wakuStoreClient.query(storeQueryRequest, peer)).valueOr:
      return err("StoreRequest failed store query: " & $error)

    let res = $(%*(queryResponse.toHex()))
    return ok(res) ## returning the response in json format
