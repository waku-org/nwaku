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
      decoded_index = Index.init(pb.buffer)

    check:
      decoded_index.value.receivedTime == index.receivedTime
      decoded_index.value.digest.data == index.digest.data


  test "PagingDirection Protobuf encod/init test":
    let
      pagingDirection = PagingDirection.BACKWARD
      pb = pagingDirection.encode()
      decodedPagingDirection = PagingDirection.init(pb.buffer)

    #var
      #emptyPagingDirection: PagingDirection
      #pbEmpty = emptyPagingDirection.encode()
      #decodedEmptyPagingDirection = PagingDirection.init(pbEmpty.buffer)

    check:
      decodedPagingDirection.value == pagingDirection
      #emptyPagingDirection.value == decodedEmptyPagingDirection

  test "PagingInfo Protobuf encod/init test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: "topic 1"))
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      pb = pagingInfo.encode()
      decodedPagingInfo = PagingInfo.init(pb.buffer)

    check:
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
      decodedQuery.value.topics == query.topics
      decodedQuery.value.pagingInfo == query.pagingInfo
