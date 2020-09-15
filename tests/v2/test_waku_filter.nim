{.used.}

import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  libp2p/[switch, standard_setup],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/[message, messages, protobuf],
  libp2p/multistream,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  ../../waku/protocol/v2/[waku_relay, waku_filter, message_notifier],
  ../test_helpers, ./utils

procSuite "Waku Filter":

  asyncTest "handle filter":
    let
      proto = WakuFilter.init()
      subscription = proto.subscription()

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      msg = Message.init(peer, @[byte 1, 2, 3], "topic", 3, false)
      msg2 = Message.init(peer, @[byte 1, 2, 3], "topic2", 4, false)

    var serverFut: Future[void]

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()
    
    var listenSwitch = newStandardSwitch(some(key))
    listenSwitch.mount(proto)
    discard await listenSwitch.start()

    var rpc = FilterRequest(contentFilter: @[ContentFilter(topics: @[])], topic: "topic")

    let conn = await dialSwitch.dial(listenSwitch.peerInfo.peerId, listenSwitch.peerInfo.addrs, WakuFilterCodec)

    await conn.writeLP(rpc.encode().buffer)
    await sleepAsync(2.seconds)

    await subscriptions.notify(msg) 
    await subscriptions.notify(msg2)
    
    var message = await conn.readLp(64*1024)

    let response = MessagePush.init(message)
    let res = response.value
    check:
      res.messages.len() == 1
      res.messages[0] == msg
