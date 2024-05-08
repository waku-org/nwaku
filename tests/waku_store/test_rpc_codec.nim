{.used.}

import std/options, testutils/unittests, chronos
import
  ../../../waku/common/protobuf,
  ../../../waku/common/paging,
  ../../../waku/waku_core,
  ../../../waku/waku_store/common,
  ../../../waku/waku_store/rpc_codec,
  ../testlib/wakucore

procSuite "Waku Store - RPC codec":
  test "StoreQueryRequest protobuf codec":
    ## Given
    let query = StoreQueryRequest(
      requestId: "0",
      includeData: true,
      pubsubTopic: some(DefaultPubsubTopic),
      contentTopics: @[DefaultContentTopic],
      startTime: some(Timestamp(10)),
      endTime: some(Timestamp(11)),
      messageHashes: @[],
      paginationCursor: none(WakuMessageHash),
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: some(DefaultPageSize),
    )

    ## When
    let pb = query.encode()
    let decodedQuery = StoreQueryRequest.decode(pb.buffer)

    ## Then
    check:
      decodedQuery.isOk()

    check:
      # the fields of decoded query decodedQuery must be the same as the original query query
      decodedQuery.value == query

  test "StoreQueryRequest protobuf codec - empty history query":
    ## Given
    let emptyQuery = StoreQueryRequest()

    ## When
    let pb = emptyQuery.encode()
    let decodedEmptyQuery = StoreQueryRequest.decode(pb.buffer)

    ## Then
    check:
      decodedEmptyQuery.isOk()

    check:
      # check the correctness of init and encode for an empty HistoryQueryRPC
      decodedEmptyQuery.value == emptyQuery

  test "StoreQueryResponse protobuf codec":
    ## Given
    let
      message = fakeWakuMessage()
      hash = computeMessageHash(DefaultPubsubTopic, message)
      keyValue = WakuMessageKeyValue(
        messageHash: hash, message: some(message), pubsubTopic: some(DefaultPubsubTopic)
      )
      res = StoreQueryResponse(
        requestId: "1",
        statusCode: 200,
        statusDesc: "it's fine",
        messages: @[keyValue],
        paginationCursor: none(WakuMessageHash),
      )

    ## When
    let pb = res.encode()
    let decodedRes = StoreQueryResponse.decode(pb.buffer)

    ## Then
    check:
      decodedRes.isOk()

    check:
      # the fields of decoded response decodedRes must be the same as the original response res
      decodedRes.value == res

  test "StoreQueryResponse protobuf codec - empty history response":
    ## Given
    let emptyRes = StoreQueryResponse()

    ## When
    let pb = emptyRes.encode()
    let decodedEmptyRes = StoreQueryResponse.decode(pb.buffer)

    ## Then
    check:
      decodedEmptyRes.isOk()

    check:
      # check the correctness of init and encode for an empty HistoryResponseRPC
      decodedEmptyRes.value == emptyRes
