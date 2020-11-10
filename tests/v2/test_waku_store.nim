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
  ../../waku/node/v2/[waku_types, message_store],
  ../test_helpers, ./utils, db_sqlite


procSuite "Waku Store":
  asyncTest "handle query":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      topic = ContentTopic(1)
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: ContentTopic(2))

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(dialSwitch, crypto.newRng())[]
      subscription = proto.subscription()
      rpc = HistoryQuery(topics: @[topic], pagingInfo: PagingInfo(direction: PagingDirection.FORWARD))

    proto.setPeer(listenSwitch.peerInfo)
    
    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    let store = MessageStore.init("", "", false, true)[]
    proto.store = store
    defer: store.close()

    await subscriptions.notify("foo", msg)
    await subscriptions.notify("foo", msg2)
    listenSwitch.mount(proto)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        response.messages[0] == msg
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  test "PagingDirection Protobuf encod/init test":
    let
      pagingDirection = PagingDirection.BACKWARD
      pb = pagingDirection.encode()
      decodedPagingDirection = PagingDirection.init(pb.buffer)

    check:
      # the decodedPagingDirection must be the same as the original pagingDirection
      decodedPagingDirection.isErr == false
      decodedPagingDirection.value == pagingDirection

  asyncTest "handle query with forward pagination":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
    
    var msgList = @[
        WakuMessage(payload: @[byte 0], contentTopic: ContentTopic(2)),
        WakuMessage(payload: @[byte 1], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 2], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 3], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 4], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 5], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 6], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 7], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 8], contentTopic: ContentTopic(1)), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic(2))
      ]

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(dialSwitch, crypto.newRng())[]
      subscription = proto.subscription()
      rpc = HistoryQuery(topics: @[ContentTopic(1)], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD))

    proto.setPeer(listenSwitch.peerInfo)

    let store = MessageStore.init("", "", false, true)[]
    proto.store = store
    defer: store.close()

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    for wakuMsg in msgList:
      await subscriptions.notify("foo", wakuMsg)

    listenSwitch.mount(proto)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      echo response
      check:
        response.messages.len() == 2
        # response.pagingInfo.pageSize == 2 
        # response.pagingInfo.direction == PagingDirection.FORWARD
        # response.pagingInfo.cursor != Index()
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  # asyncTest "handle query with backward pagination":
  #   let
  #     key = PrivateKey.random(ECDSA, rng[]).get()
  #     peer = PeerInfo.init(key)
  #   var
  #     msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic(2)),
  #       WakuMessage(payload: @[byte 1],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 2],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 3],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 4],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 5],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 6],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 7],contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 8],contentTopic: ContentTopic(1)), 
  #       WakuMessage(payload: @[byte 9],contentTopic: ContentTopic(2))]

  #   var dialSwitch = newStandardSwitch()
  #   discard await dialSwitch.start()

  #   var listenSwitch = newStandardSwitch(some(key))
  #   discard await listenSwitch.start()

  #   let
  #     proto = WakuStore.init(dialSwitch, crypto.newRng())[]
  #     subscription = proto.subscription()
  #   proto.setPeer(listenSwitch.peerInfo)
    
  #   let store = MessageStore.init("", "", false, true)[]
  #   proto.store = store
  #   defer: store.close()

  #   var subscriptions = newTable[string, MessageNotificationSubscription]()
  #   subscriptions["test"] = subscription

  #   listenSwitch.mount(proto)

  #   for wakuMsg in msgList:
  #     await subscriptions.notify("foo", wakuMsg)
  #   var completionFut = newFuture[bool]()

  #   proc handler(response: HistoryResponse) {.gcsafe, closure.} =
  #     check:
  #       response.messages.len() == 2
  #       response.pagingInfo.pageSize == 2 
  #       response.pagingInfo.direction == PagingDirection.BACKWARD
  #       response.pagingInfo.cursor != Index()
  #     completionFut.complete(true)

  #   let rpc = HistoryQuery(topics: @[ContentTopic(1)], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD))
  #   await proto.query(rpc, handler)

  #   check:
  #     (await completionFut.withTimeout(5.seconds)) == true

  # asyncTest "handle queries with no pagination":
  #   let
  #     key = PrivateKey.random(ECDSA, rng[]).get()
  #     peer = PeerInfo.init(key)
  #   var
  #     msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic(2)),
  #       WakuMessage(payload: @[byte 1], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 2], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 3], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 4], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 5], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 6], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 7], contentTopic: ContentTopic(1)),
  #       WakuMessage(payload: @[byte 8], contentTopic: ContentTopic(1)), 
  #       WakuMessage(payload: @[byte 9], contentTopic: ContentTopic(2))]

  #   var dialSwitch = newStandardSwitch()
  #   discard await dialSwitch.start()

  #   var listenSwitch = newStandardSwitch(some(key))
  #   discard await listenSwitch.start()

  #   let
  #     proto = WakuStore.init(dialSwitch, crypto.newRng())[]
  #     subscription = proto.subscription()
  #   proto.setPeer(listenSwitch.peerInfo)

  #   let store = MessageStore.init("", "", false, true)[]
  #   proto.store = store
  #   defer: store.close()

  #   var subscriptions = newTable[string, MessageNotificationSubscription]()
  #   subscriptions["test"] = subscription

  #   listenSwitch.mount(proto)

  #   for wakuMsg in msgList:
  #     await subscriptions.notify("foo", wakuMsg)
  #   var completionFut = newFuture[bool]()

  #   proc handler(response: HistoryResponse) {.gcsafe, closure.} =
  #     check:
  #       response.messages.len() == 8
  #       response.pagingInfo == PagingInfo()
  #     completionFut.complete(true)

  #   let rpc = HistoryQuery(topics: @[ContentTopic(1)])

  #   await proto.query(rpc, handler)

  #   check:
  #     (await completionFut.withTimeout(5.seconds)) == true