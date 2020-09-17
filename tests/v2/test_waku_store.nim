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
      proto = WakuStore.init()
      subscription = proto.subscription()

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic")
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")

    var serverFut: Future[void]

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    listenSwitch.mount(proto)
    discard await listenSwitch.start()

    await subscriptions.notify("foo", msg)
    await subscriptions.notify("foo", msg2)

    let conn = await dialSwitch.dial(listenSwitch.peerInfo.peerId, listenSwitch.peerInfo.addrs, WakuStoreCodec)

    var rpc = HistoryQuery(uuid: "1234", topics: @["topic"])
    await conn.writeLP(rpc.encode().buffer)

    var message = await conn.readLp(64*1024)
    let response = HistoryResponse.init(message)

    check:
      response.isErr == false
      response.value.uuid == rpc.uuid
      response.value.messages.len() == 1
      response.value.messages[0] == msg
