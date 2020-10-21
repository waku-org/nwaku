{.used.}

import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  ../../waku/protocol/v2/[waku_relay, waku_filter, message_notifier],
  ../../waku/node/v2/waku_types,
  ../test_helpers, ./utils

procSuite "Waku Filter":

  asyncTest "handle filter":

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      contentTopic = ContentTopic(1)
      post = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    var responseRequestIdFuture = newFuture[string]()
    proc handle(requestId: string, msg: MessagePush) {.gcsafe, closure.} =
      check:
        msg.messages.len() == 1
        msg.messages[0] == post
      responseRequestIdFuture.complete(requestId)

    let
      proto = WakuFilter.init(dialSwitch, crypto.newRng(), handle)
      rpc = FilterRequest(contentFilters: @[ContentFilter(topics: @[contentTopic])], topic: "topic")

    dialSwitch.mount(proto)
    proto.setPeer(listenSwitch.peerInfo)

    proc emptyHandle(requestId: string, msg: MessagePush) {.gcsafe, closure.} =
      discard

    let 
      proto2 = WakuFilter.init(listenSwitch, crypto.newRng(), emptyHandle)
      subscription = proto2.subscription()

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription
    listenSwitch.mount(proto2)

    let id = await proto.subscribe(rpc)

    await sleepAsync(2.seconds)

    await subscriptions.notify("topic", post)

    check:
      (await responseRequestIdFuture) == id
