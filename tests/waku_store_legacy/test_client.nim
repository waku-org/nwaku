{.used.}

import std/options, testutils/unittests, chronos, chronicles, libp2p/crypto/crypto

import
  ../../../waku/[
    node/peer_manager,
    waku_core,
    waku_store_legacy,
    waku_store_legacy/client,
    common/paging,
  ],
  ../testlib/[common, wakucore, testasync, futures],
  ./store_utils

suite "Store Client":
  var message1 {.threadvar.}: WakuMessage
  var message2 {.threadvar.}: WakuMessage
  var message3 {.threadvar.}: WakuMessage
  var messageSeq {.threadvar.}: seq[WakuMessage]
  var handlerFuture {.threadvar.}: Future[HistoryQuery]
  var handler {.threadvar.}: HistoryQueryHandler
  var historyQuery {.threadvar.}: HistoryQuery

  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch

  var server {.threadvar.}: WakuStore
  var client {.threadvar.}: WakuStoreClient

  var serverPeerInfo {.threadvar.}: RemotePeerInfo
  var clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    echo "-------------------- 1 --------------------"
    message1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    message2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    message3 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    echo "-------------------- 2 --------------------"
    messageSeq = @[message1, message2, message3]
    echo "-------------------- 3 --------------------"
    handlerFuture = newLegacyHistoryFuture()
    echo "-------------------- 4 --------------------"
    handler = proc(req: HistoryQuery): Future[HistoryResult] {.async, gcsafe.} =
      handlerFuture.complete(req)
      return ok(HistoryResponse(messages: messageSeq))
    historyQuery = HistoryQuery(
      pubsubTopic: some(DefaultPubsubTopic),
      contentTopics: @[DefaultContentTopic],
      direction: PagingDirection.FORWARD,
    )

    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()
    echo "-------------------- 5 --------------------"

    server = await newTestWakuStore(serverSwitch, handler = handler)
    echo "-------------------- 6 --------------------"
    client = newTestWakuStoreClient(clientSwitch)
    echo "-------------------- 7 --------------------"

    await allFutures(serverSwitch.start(), clientSwitch.start())
    echo "-------------------- 8 --------------------"

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    echo "-------------------- 9 --------------------"
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()
    echo "-------------------- 10 --------------------"

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  suite "HistoryQuery Creation and Execution":
    asyncTest "Valid Queries":
      # When a valid query is sent to the server
      echo "-------------------- 11 --------------------"
      let queryResponse = await client.query(historyQuery, peer = serverPeerInfo)
      echo "-------------------- 12 --------------------"

      # Then the query is processed successfully
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 13 --------------------"
      check:
        handlerFuture.read() == historyQuery
        queryResponse.get().messages == messageSeq
      echo "-------------------- 14 --------------------"

    asyncTest "Invalid Queries":
      echo "-------------------- 15 --------------------"
      # TODO: IMPROVE: We can't test "actual" invalid queries because 
      # it directly depends on the handler implementation, to achieve
      # proper coverage we'd need an example implementation.

      # Given some invalid queries
      let
        invalidQuery1 = HistoryQuery(
          pubsubTopic: some(DefaultPubsubTopic),
          contentTopics: @[],
          direction: PagingDirection.FORWARD,
        )
        invalidQuery2 = HistoryQuery(
          pubsubTopic: PubsubTopic.none(),
          contentTopics: @[DefaultContentTopic],
          direction: PagingDirection.FORWARD,
        )
        invalidQuery3 = HistoryQuery(
          pubsubTopic: some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          pageSize: 0,
        )
        invalidQuery4 = HistoryQuery(
          pubsubTopic: some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          pageSize: 0,
        )
        invalidQuery5 = HistoryQuery(
          pubsubTopic: some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          startTime: some(0.Timestamp),
          endTime: some(0.Timestamp),
        )
        invalidQuery6 = HistoryQuery(
          pubsubTopic: some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          startTime: some(0.Timestamp),
          endTime: some(-1.Timestamp),
        )

      echo "-------------------- 16 --------------------"
      # When the query is sent to the server
      let queryResponse1 = await client.query(invalidQuery1, peer = serverPeerInfo)

      echo "-------------------- 17 --------------------"
      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 18 --------------------"
      check:
        handlerFuture.read() == invalidQuery1
        queryResponse1.get().messages == messageSeq
      echo "-------------------- 19 --------------------"

      # When the query is sent to the server
      handlerFuture = newLegacyHistoryFuture()
      let queryResponse2 = await client.query(invalidQuery2, peer = serverPeerInfo)
      echo "-------------------- 20 --------------------"

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 21 --------------------"
      check:
        handlerFuture.read() == invalidQuery2
        queryResponse2.get().messages == messageSeq
      echo "-------------------- 22 --------------------"

      # When the query is sent to the server
      handlerFuture = newLegacyHistoryFuture()
      let queryResponse3 = await client.query(invalidQuery3, peer = serverPeerInfo)
      echo "-------------------- 23 --------------------"

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 24 --------------------"
      check:
        handlerFuture.read() == invalidQuery3
        queryResponse3.get().messages == messageSeq
      echo "-------------------- 25 --------------------"

      # When the query is sent to the server
      handlerFuture = newLegacyHistoryFuture()
      let queryResponse4 = await client.query(invalidQuery4, peer = serverPeerInfo)
      echo "-------------------- 26 --------------------"

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 27 --------------------"
      check:
        handlerFuture.read() == invalidQuery4
        queryResponse4.get().messages == messageSeq

      echo "-------------------- 28 --------------------"
      # When the query is sent to the server
      handlerFuture = newLegacyHistoryFuture()
      let queryResponse5 = await client.query(invalidQuery5, peer = serverPeerInfo)

      echo "-------------------- 29 --------------------"
      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 30 --------------------"
      check:
        handlerFuture.read() == invalidQuery5
        queryResponse5.get().messages == messageSeq
      echo "-------------------- 31 --------------------"

      # When the query is sent to the server
      handlerFuture = newLegacyHistoryFuture()
      let queryResponse6 = await client.query(invalidQuery6, peer = serverPeerInfo)
      echo "-------------------- 32 --------------------"

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      echo "-------------------- 33 --------------------"
      check:
        handlerFuture.read() == invalidQuery6
        queryResponse6.get().messages == messageSeq
      echo "-------------------- 34 --------------------"

  suite "Verification of HistoryResponse Payload":
    asyncTest "Positive Responses":
      echo "-------------------- 35 --------------------"
      # When a valid query is sent to the server
      let queryResponse = await client.query(historyQuery, peer = serverPeerInfo)
      echo "-------------------- 36 --------------------"

      # Then the query is processed successfully, and is of the expected type
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        type(queryResponse.get()) is HistoryResponse
      echo "-------------------- 37 --------------------"

    asyncTest "Negative Responses - PeerDialFailure":
      echo "-------------------- 38 --------------------"
      # Given a stopped peer
      let
        otherServerSwitch = newTestSwitch()
        otherServerPeerInfo = otherServerSwitch.peerInfo.toRemotePeerInfo()
      echo "-------------------- 39 --------------------"

      # When a query is sent to the stopped peer
      let queryResponse = await client.query(historyQuery, peer = otherServerPeerInfo)
      echo "-------------------- 40 --------------------"

      # Then the query is not processed
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        queryResponse.isErr()
        queryResponse.error.kind == HistoryErrorKind.PEER_DIAL_FAILURE
      echo "-------------------- 41 --------------------"
