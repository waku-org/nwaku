{.used.}

import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/message,
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  ../../waku/protocol/v2/[waku_store, message_notifier],
  ../../waku/node/v2/waku_types,
  ../test_helpers, ./utils

procSuite "Waku Store":
  asyncTest "handle query":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic")
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(dialSwitch, crypto.newRng())
      subscription = proto.subscription()
      rpc = HistoryQuery(topics: @["topic"])

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    await subscriptions.notify("foo", msg)
    await subscriptions.notify("foo", msg2)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        response.messages[0] == msg
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  test "Index Protobuf encoder/decoder test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: "topic 1"))
      pb = index.encode()
      decodedIndex = Index.init(pb.buffer)

    check:
      # the fields of decodedIndex must be the same as the original index
      decodedIndex.value.receivedTime == index.receivedTime
      decodedIndex.value.digest.data == index.digest.data


  test "PagingDirection Protobuf encod/init test":
    let
      pagingDirection = PagingDirection.BACKWARD
      pb = pagingDirection.encode()
      decodedPagingDirection = PagingDirection.init(pb.buffer)

    check:
      # the decodedPagingDirection must be the same as the original pagingDirection
      decodedPagingDirection.value == pagingDirection

  test "PagingInfo Protobuf encod/init test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: "topic 1"))
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      pb = pagingInfo.encode()
      decodedPagingInfo = PagingInfo.init(pb.buffer)

    check:
      # the fields of decodedPagingInfo must be the same as the original pagingInfo
      decodedPagingInfo.value.pageSize == pagingInfo.pageSize
      decodedPagingInfo.value.cursor == pagingInfo.cursor
      decodedPagingInfo.value.direction == pagingInfo.direction
  
  test "HistoryQuery Protobuf encod/init test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: "topic 1"))
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      query=HistoryQuery(topics: @["topic1"], pagingInfo: pagingInfo)
      pb = query.encode()
      decodedQuery = HistoryQuery.init(pb.buffer)

    check:
      # the fields of decoded query decodedQuery must be the same as the original query query
      decodedQuery.value.topics == query.topics
      decodedQuery.value.pagingInfo == query.pagingInfo
  
  test "HistoryResponse Protobuf encod/init test":
    let
      wm = WakuMessage(payload: @[byte 1], contentTopic: "topic 1")
      index = computeIndex(wm)
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      res=HistoryResponse(messages: @[wm], pagingInfo: pagingInfo)
      pb = res.encode()
      decodedRes = HistoryResponse.init(pb.buffer)

    check:
      # the fields of decoded response decodedRes must be the same as the original response res
      decodedRes.value.messages == res.messages
      decodedRes.value.pagingInfo == res.pagingInfo
