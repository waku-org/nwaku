when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sequtils],
  stew/results
import
  ../../utils/time,
  ../waku_message,
  ./common


## Wire protocol

type PagingIndexRPC* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  pubsubTopic*: PubsubTopic
  senderTime*: Timestamp # the time at which the message is generated
  receiverTime*: Timestamp
  digest*: MessageDigest # calculated over payload and content topic

proc `==`*(x, y: PagingIndexRPC): bool =
  ## receiverTime plays no role in index equality
  (x.senderTime == y.senderTime) and
  (x.digest == y.digest) and
  (x.pubsubTopic == y.pubsubTopic)

proc compute*(T: type PagingIndexRPC, msg: WakuMessage, receivedTime: Timestamp, pubsubTopic: PubsubTopic): T =
  ## Takes a WakuMessage with received timestamp and returns its Index.
  let
    digest = computeDigest(msg)
    senderTime = msg.timestamp

  PagingIndexRPC(
    pubsubTopic: pubsubTopic,
    senderTime: senderTime,
    receiverTime: receivedTime, 
    digest: digest
  )


type
  PagingDirectionRPC* {.pure.} = enum
    ## PagingDirection determines the direction of pagination
    BACKWARD = uint32(0)
    FORWARD = uint32(1)

  PagingInfoRPC* = object
    ## This type holds the information needed for the pagination
    pageSize*: uint64
    cursor*: PagingIndexRPC
    direction*: PagingDirectionRPC


type
  HistoryContentFilterRPC* = object
    contentTopic*: ContentTopic

  HistoryQueryRPC* = object
    contentFilters*: seq[HistoryContentFilterRPC]
    pubsubTopic*: PubsubTopic
    pagingInfo*: PagingInfoRPC # used for pagination
    startTime*: Timestamp # used for time-window query
    endTime*: Timestamp # used for time-window query

  HistoryResponseErrorRPC* {.pure.} = enum
    ## HistoryResponseErrorRPC contains error message to inform  the querying node about 
    ## the state of its request
    NONE = uint32(0)
    INVALID_CURSOR = uint32(1)
    SERVICE_UNAVAILABLE = uint32(503)

  HistoryResponseRPC* = object
    messages*: seq[WakuMessage]
    pagingInfo*: PagingInfoRPC # used for pagination
    error*: HistoryResponseErrorRPC

  HistoryRPC* = object
    requestId*: string
    query*: HistoryQueryRPC
    response*: HistoryResponseRPC


proc parse*(T: type HistoryResponseErrorRPC, kind: uint32): T =
  case kind:
  of 0, 1, 503:
    HistoryResponseErrorRPC(kind)
  else:
    # TODO: Improve error variants/move to satus codes
    HistoryResponseErrorRPC.INVALID_CURSOR


## Wire protocol type mappings

proc toRPC*(cursor: HistoryCursor): PagingIndexRPC {.gcsafe.}=
  PagingIndexRPC(
    pubsubTopic: cursor.pubsubTopic,
    senderTime: cursor.senderTime,
    receiverTime: cursor.storeTime,
    digest: cursor.digest
  )

proc toAPI*(rpc: PagingIndexRPC): HistoryCursor =
  HistoryCursor(
    pubsubTopic: rpc.pubsubTopic,
    senderTime: rpc.senderTime,
    storeTime: rpc.receiverTime,
    digest: rpc.digest
  )


proc toRPC*(query: HistoryQuery): HistoryQueryRPC =
  let 
    contentFilters = query.contentTopics.mapIt(HistoryContentFilterRPC(contentTopic: it))

    pubsubTopic = query.pubsubTopic.get(default(string))
  
    pageSize = query.pageSize

    cursor = query.cursor.get(default(HistoryCursor)).toRPC()

    direction = if query.ascending: PagingDirectionRPC.FORWARD
                else: PagingDirectionRPC.BACKWARD

    startTime = query.startTime.get(default(Timestamp))
    
    endTime = query.endTime.get(default(Timestamp))

  HistoryQueryRPC(
    contentFilters: contentFilters,
    pubsubTopic: pubsubTopic,
    pagingInfo: PagingInfoRPC(
      pageSize: pageSize,
      cursor: cursor,
      direction: direction
    ),
    startTime: startTime,
    endTime: endTime
  )

proc toAPI*(rpc: HistoryQueryRPC): HistoryQuery =
  let 
    pubsubTopic = if rpc.pubsubTopic == default(string): none(PubsubTopic)
                  else: some(rpc.pubsubTopic)
    
    contentTopics = rpc.contentFilters.mapIt(it.contentTopic)

    cursor = if rpc.pagingInfo == default(PagingInfoRPC) or rpc.pagingInfo.cursor == default(PagingIndexRPC): none(HistoryCursor)
             else: some(rpc.pagingInfo.cursor.toAPI())

    startTime = if rpc.startTime == default(Timestamp): none(Timestamp)
                else: some(rpc.startTime)

    endTime = if rpc.endTime == default(Timestamp): none(Timestamp)
              else: some(rpc.endTime)
    
    pageSize = if rpc.pagingInfo == default(PagingInfoRPC): 0.uint64
               else: rpc.pagingInfo.pageSize

    ascending = if rpc.pagingInfo == default(PagingInfoRPC): true
                else: rpc.pagingInfo.direction == PagingDirectionRPC.FORWARD
    
  HistoryQuery(
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics,
    cursor: cursor,
    startTime: startTime,
    endTime: endTime,
    pageSize: pageSize,
    ascending: ascending
  )


proc toRPC*(err: HistoryError): HistoryResponseErrorRPC =
  # TODO: Better error mappings/move to error codes
  case err.kind:
  of HistoryErrorKind.BAD_REQUEST:
    # TODO: Respond aksi with the reason
    HistoryResponseErrorRPC.INVALID_CURSOR
  of HistoryErrorKind.SERVICE_UNAVAILABLE:
    HistoryResponseErrorRPC.SERVICE_UNAVAILABLE
  else:
    HistoryResponseErrorRPC.INVALID_CURSOR    

proc toAPI*(err: HistoryResponseErrorRPC): HistoryError =
  # TODO: Better error mappings/move to error codes
  case err:
  of HistoryResponseErrorRPC.INVALID_CURSOR:
    HistoryError(kind: HistoryErrorKind.BAD_REQUEST, cause: "invalid cursor")
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
          default(PagingInfoRPC)
        else: 
          let
            pageSize = resp.pageSize
            cursor = resp.cursor.get(default(HistoryCursor)).toRPC()
            direction = if resp.ascending: PagingDirectionRPC.FORWARD
                        else: PagingDirectionRPC.BACKWARD
          PagingInfoRPC(
            pageSize: pageSize,
            cursor: cursor,
            direction: direction
          )

      error = HistoryResponseErrorRPC.NONE

    HistoryResponseRPC(
      messages: messages,
      pagingInfo: pagingInfo,
      error: error
    )

proc toAPI*(rpc: HistoryResponseRPC): HistoryResult =
  if rpc.error != HistoryResponseErrorRPC.NONE:
    err(rpc.error.toAPI())
  else:
    let
      messages = rpc.messages

      pageSize = rpc.pagingInfo.pageSize

      ascending = rpc.pagingInfo == default(PagingInfoRPC) or rpc.pagingInfo.direction == PagingDirectionRPC.FORWARD

      cursor = if rpc.pagingInfo == default(PagingInfoRPC) or rpc.pagingInfo.cursor == default(PagingIndexRPC): none(HistoryCursor)
               else: some(rpc.pagingInfo.cursor.toAPI())

    ok(HistoryResponse(
      messages: messages,
      pageSize: pageSize,
      ascending: ascending,
      cursor: cursor
    ))
