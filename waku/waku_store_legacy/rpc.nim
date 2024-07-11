{.push raises: [].}

import std/[options, sequtils], results
import ../waku_core, ../common/paging, ./common

## Wire protocol

const HistoryQueryDirectionDefaultValue = default(type HistoryQuery.direction)

type PagingIndexRPC* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  pubsubTopic*: PubsubTopic
  senderTime*: Timestamp # the time at which the message is generated
  receiverTime*: Timestamp
  digest*: MessageDigest # calculated over payload and content topic

proc `==`*(x, y: PagingIndexRPC): bool =
  ## receiverTime plays no role in index equality
  (x.senderTime == y.senderTime) and (x.digest == y.digest) and
    (x.pubsubTopic == y.pubsubTopic)

proc compute*(
    T: type PagingIndexRPC,
    msg: WakuMessage,
    receivedTime: Timestamp,
    pubsubTopic: PubsubTopic,
): T =
  ## Takes a WakuMessage with received timestamp and returns its Index.
  let
    digest = computeDigest(msg)
    senderTime = msg.timestamp

  PagingIndexRPC(
    pubsubTopic: pubsubTopic,
    senderTime: senderTime,
    receiverTime: receivedTime,
    digest: digest,
  )

type PagingInfoRPC* = object
  ## This type holds the information needed for the pagination
  pageSize*: Option[uint64]
  cursor*: Option[PagingIndexRPC]
  direction*: Option[PagingDirection]

type
  HistoryContentFilterRPC* = object
    contentTopic*: ContentTopic

  HistoryQueryRPC* = object
    contentFilters*: seq[HistoryContentFilterRPC]
    pubsubTopic*: Option[PubsubTopic]
    pagingInfo*: Option[PagingInfoRPC]
    startTime*: Option[int64]
    endTime*: Option[int64]

  HistoryResponseErrorRPC* {.pure.} = enum
    ## HistoryResponseErrorRPC contains error message to inform  the querying node about
    ## the state of its request
    NONE = uint32(0)
    INVALID_CURSOR = uint32(1)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)

  HistoryResponseRPC* = object
    messages*: seq[WakuMessage]
    pagingInfo*: Option[PagingInfoRPC]
    error*: HistoryResponseErrorRPC

  HistoryRPC* = object
    requestId*: string
    query*: Option[HistoryQueryRPC]
    response*: Option[HistoryResponseRPC]

proc parse*(T: type HistoryResponseErrorRPC, kind: uint32): T =
  case kind
  of 0, 1, 429, 503:
    HistoryResponseErrorRPC(kind)
  else:
    # TODO: Improve error variants/move to satus codes
    HistoryResponseErrorRPC.INVALID_CURSOR

## Wire protocol type mappings

proc toRPC*(cursor: HistoryCursor): PagingIndexRPC {.gcsafe.} =
  PagingIndexRPC(
    pubsubTopic: cursor.pubsubTopic,
    senderTime: cursor.senderTime,
    receiverTime: cursor.storeTime,
    digest: cursor.digest,
  )

proc toAPI*(rpc: PagingIndexRPC): HistoryCursor =
  HistoryCursor(
    pubsubTopic: rpc.pubsubTopic,
    senderTime: rpc.senderTime,
    storeTime: rpc.receiverTime,
    digest: rpc.digest,
  )

proc toRPC*(query: HistoryQuery): HistoryQueryRPC =
  var rpc = HistoryQueryRPC()

  rpc.contentFilters =
    query.contentTopics.mapIt(HistoryContentFilterRPC(contentTopic: it))

  rpc.pubsubTopic = query.pubsubTopic

  rpc.pagingInfo = block:
    if query.cursor.isNone() and query.pageSize == default(type query.pageSize) and
        query.direction == HistoryQueryDirectionDefaultValue:
      none(PagingInfoRPC)
    else:
      let
        pageSize = some(query.pageSize)
        cursor = query.cursor.map(toRPC)
        direction = some(query.direction)

      some(PagingInfoRPC(pageSize: pageSize, cursor: cursor, direction: direction))

  rpc.startTime = query.startTime
  rpc.endTime = query.endTime

  rpc

proc toAPI*(rpc: HistoryQueryRPC): HistoryQuery =
  let
    pubsubTopic = rpc.pubsubTopic

    contentTopics = rpc.contentFilters.mapIt(it.contentTopic)

    cursor =
      if rpc.pagingInfo.isNone() or rpc.pagingInfo.get().cursor.isNone():
        none(HistoryCursor)
      else:
        rpc.pagingInfo.get().cursor.map(toAPI)

    startTime = rpc.startTime

    endTime = rpc.endTime

    pageSize =
      if rpc.pagingInfo.isNone() or rpc.pagingInfo.get().pageSize.isNone():
        0'u64
      else:
        rpc.pagingInfo.get().pageSize.get()

    direction =
      if rpc.pagingInfo.isNone() or rpc.pagingInfo.get().direction.isNone():
        HistoryQueryDirectionDefaultValue
      else:
        rpc.pagingInfo.get().direction.get()

  HistoryQuery(
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics,
    cursor: cursor,
    startTime: startTime,
    endTime: endTime,
    pageSize: pageSize,
    direction: direction,
  )

proc toRPC*(err: HistoryError): HistoryResponseErrorRPC =
  # TODO: Better error mappings/move to error codes
  case err.kind
  of HistoryErrorKind.BAD_REQUEST:
    # TODO: Respond aksi with the reason
    HistoryResponseErrorRPC.INVALID_CURSOR
  of HistoryErrorKind.TOO_MANY_REQUESTS:
    HistoryResponseErrorRPC.TOO_MANY_REQUESTS
  of HistoryErrorKind.SERVICE_UNAVAILABLE:
    HistoryResponseErrorRPC.SERVICE_UNAVAILABLE
  else:
    HistoryResponseErrorRPC.INVALID_CURSOR

proc toAPI*(err: HistoryResponseErrorRPC): HistoryError =
  # TODO: Better error mappings/move to error codes
  case err
  of HistoryResponseErrorRPC.INVALID_CURSOR:
    HistoryError(kind: HistoryErrorKind.BAD_REQUEST, cause: "invalid cursor")
  of HistoryResponseErrorRPC.TOO_MANY_REQUESTS:
    HistoryError(kind: HistoryErrorKind.TOO_MANY_REQUESTS)
  of HistoryResponseErrorRPC.SERVICE_UNAVAILABLE:
    HistoryError(kind: HistoryErrorKind.SERVICE_UNAVAILABLE)
  else:
    HistoryError(kind: HistoryErrorKind.UNKNOWN)

proc toRPC*(res: HistoryResult): HistoryResponseRPC =
  if res.isErr():
    let error = res.error.toRPC()

    HistoryResponseRPC(error: error)
  else:
    let resp = res.get()

    let
      messages = resp.messages

      pagingInfo = block:
        if resp.cursor.isNone():
          none(PagingInfoRPC)
        else:
          some(PagingInfoRPC(cursor: resp.cursor.map(toRPC)))

      error = HistoryResponseErrorRPC.NONE

    HistoryResponseRPC(messages: messages, pagingInfo: pagingInfo, error: error)

proc toAPI*(rpc: HistoryResponseRPC): HistoryResult =
  if rpc.error != HistoryResponseErrorRPC.NONE:
    err(rpc.error.toAPI())
  else:
    let
      messages = rpc.messages

      cursor =
        if rpc.pagingInfo.isNone():
          none(HistoryCursor)
        else:
          rpc.pagingInfo.get().cursor.map(toAPI)

    ok(HistoryResponse(messages: messages, cursor: cursor))
