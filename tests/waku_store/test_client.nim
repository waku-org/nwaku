{.used.}

import std/options, testutils/unittests, chronos, chronicles, libp2p/crypto/crypto

import
  ../../../waku/
    [node/peer_manager, waku_core, waku_store, waku_store/client, common/paging],
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
    message1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    message2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    message3 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    messageSeq = @[message1, message2, message3]
    handlerFuture = newHistoryFuture()
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

    server = await newTestWakuStore(serverSwitch, handler = handler)
    client = newTestWakuStoreClient(clientSwitch)

    await allFutures(serverSwitch.start(), clientSwitch.start())

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  suite "HistoryQuery Creation and Execution":
    asyncTest "Valid Queries":
      # When a valid query is sent to the server
      let queryResponse = await client.query(historyQuery, peer = serverPeerInfo)

      # Then the query is processed successfully
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == historyQuery
        queryResponse.get().messages == messageSeq

    asyncTest "Invalid Queries":
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

      # When the query is sent to the server
      let queryResponse1 = await client.query(invalidQuery1, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery1
        queryResponse1.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse2 = await client.query(invalidQuery2, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery2
        queryResponse2.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse3 = await client.query(invalidQuery3, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery3
        queryResponse3.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse4 = await client.query(invalidQuery4, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery4
        queryResponse4.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse5 = await client.query(invalidQuery5, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery5
        queryResponse5.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse6 = await client.query(invalidQuery6, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery6
        queryResponse6.get().messages == messageSeq

  suite "Verification of HistoryResponse Payload":
    asyncTest "Positive Responses":
      # When a valid query is sent to the server
      let queryResponse = await client.query(historyQuery, peer = serverPeerInfo)

      # Then the query is processed successfully, and is of the expected type
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        type(queryResponse.get()) is HistoryResponse

    asyncTest "Negative Responses - PeerDialFailure":
      # Given a stopped peer
      let
        otherServerSwitch = newTestSwitch()
        otherServerPeerInfo = otherServerSwitch.peerInfo.toRemotePeerInfo()

      # When a query is sent to the stopped peer
      let queryResponse = await client.query(historyQuery, peer = otherServerPeerInfo)

      # Then the query is not processed
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        queryResponse.isErr()
        queryResponse.error.kind == HistoryErrorKind.PEER_DIAL_FAILURE
