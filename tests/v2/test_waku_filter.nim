{.used.}

import
  std/[options, tables, sets],
  testutils/unittests, chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/multistream,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../test_helpers, ./utils

procSuite "Waku Filter":

  asyncTest "handle filter":
    const defaultTopic = "/waku/2/default-waku/proto"

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      post = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    var responseRequestIdFuture = newFuture[string]()
    proc handle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      check:
        msg.messages.len() == 1
        msg.messages[0] == post
      responseRequestIdFuture.complete(requestId)

    let
      proto = WakuFilter.init(PeerManager.new(dialSwitch), crypto.newRng(), handle)
      rpc = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], pubSubTopic: defaultTopic, subscribe: true)

    dialSwitch.mount(proto)
    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    proc emptyHandle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      discard

    let proto2 = WakuFilter.init(PeerManager.new(listenSwitch), crypto.newRng(), emptyHandle)

    listenSwitch.mount(proto2)

    let id = (await proto.subscribe(rpc)).get()

    await sleepAsync(2.seconds)

    await proto2.handleMessage(defaultTopic, post)

    check:
      (await responseRequestIdFuture) == id
  
  asyncTest "Can subscribe and unsubscribe from content filter":
    const defaultTopic = "/waku/2/default-waku/proto"

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      post = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    var responseCompletionFuture = newFuture[bool]()
    proc handle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      check:
        msg.messages.len() == 1
        msg.messages[0] == post
      responseCompletionFuture.complete(true)

    let
      proto = WakuFilter.init(PeerManager.new(dialSwitch), crypto.newRng(), handle)
      rpc = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], pubSubTopic: defaultTopic, subscribe: true)

    dialSwitch.mount(proto)
    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    proc emptyHandle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      discard

    let proto2 = WakuFilter.init(PeerManager.new(listenSwitch), crypto.newRng(), emptyHandle)

    listenSwitch.mount(proto2)

    let id = (await proto.subscribe(rpc)).get()

    await sleepAsync(2.seconds)

    await proto2.handleMessage(defaultTopic, post)

    check:
      # Check that subscription works as expected
      (await responseCompletionFuture.withTimeout(3.seconds)) == true
    
    # Reset to test unsubscribe
    responseCompletionFuture = newFuture[bool]()

    let
      rpcU = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], pubSubTopic: defaultTopic, subscribe: false)

    await proto.unsubscribe(rpcU)

    await sleepAsync(2.seconds)

    await proto2.handleMessage(defaultTopic, post)

    check:
      # Check that unsubscribe works as expected
      (await responseCompletionFuture.withTimeout(5.seconds)) == false
  
  asyncTest "handle filter subscribe failures":
    const defaultTopic = "/waku/2/default-waku/proto"

    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var responseRequestIdFuture = newFuture[string]()
    proc handle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      discard

    let
      proto = WakuFilter.init(PeerManager.new(dialSwitch), crypto.newRng(), handle)
      rpc = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], pubSubTopic: defaultTopic, subscribe: true)

    dialSwitch.mount(proto)

    let idOpt = (await proto.subscribe(rpc))

    check:
      idOpt.isNone

  asyncTest "Handle failed clients":
    const defaultTopic = "/waku/2/default-waku/proto"

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      post = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    var responseCompletionFuture = newFuture[bool]()
    proc handle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      check:
        msg.messages.len() == 1
        msg.messages[0] == post
      responseCompletionFuture.complete(true)

    let
      proto = WakuFilter.init(PeerManager.new(dialSwitch), crypto.newRng(), handle)
      rpc = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], pubSubTopic: defaultTopic, subscribe: true)

    dialSwitch.mount(proto)
    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    proc emptyHandle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      discard

    let proto2 = WakuFilter.init(PeerManager.new(listenSwitch), crypto.newRng(), emptyHandle, 1.seconds)

    listenSwitch.mount(proto2)

    let id = (await proto.subscribe(rpc)).get()

    await sleepAsync(2.seconds)

    await proto2.handleMessage(defaultTopic, post)

    check:
      # Check that subscription works as expected
      (await responseCompletionFuture.withTimeout(3.seconds)) == true
    
    # Stop switch to test unsubscribe
    discard dialSwitch.stop()

    await sleepAsync(2.seconds)
    
    #First failure should not remove the subscription
    await proto2.handleMessage(defaultTopic, post)

    await sleepAsync(2000.millis)
    check:
      proto2.subscribers.len() == 1
    
    #Second failure should remove the subscription
    await proto2.handleMessage(defaultTopic, post)
    
    check:
      proto2.subscribers.len() == 0
  
  asyncTest "Handles failed clients coming back up":
    const defaultTopic = "/waku/2/default-waku/proto"

    let
      dialKey = PrivateKey.random(ECDSA, rng[]).get()
      listenKey = PrivateKey.random(ECDSA, rng[]).get()
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      post = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)

    var dialSwitch = newStandardSwitch(privKey = some(dialKey), addrs = MultiAddress.init("/ip4/127.0.0.1/tcp/65000").tryGet())
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(listenKey))
    await listenSwitch.start()

    var responseCompletionFuture = newFuture[bool]()
    proc handle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      check:
        msg.messages.len() == 1
        msg.messages[0] == post
      responseCompletionFuture.complete(true)

    let
      proto = WakuFilter.init(PeerManager.new(dialSwitch), crypto.newRng(), handle)
      rpc = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], pubSubTopic: defaultTopic, subscribe: true)

    dialSwitch.mount(proto)
    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    proc emptyHandle(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} =
      discard

    let proto2 = WakuFilter.init(PeerManager.new(listenSwitch), crypto.newRng(), emptyHandle, 2.seconds)

    listenSwitch.mount(proto2)

    let id = (await proto.subscribe(rpc)).get()

    await sleepAsync(2.seconds)

    await proto2.handleMessage(defaultTopic, post)

    check:
      # Check that subscription works as expected
      (await responseCompletionFuture.withTimeout(3.seconds)) == true
    
    responseCompletionFuture = newFuture[bool]()

    # Stop switch to test unsubscribe
    await dialSwitch.stop()

    await sleepAsync(1.seconds)
    
    #First failure should add to failure list
    await proto2.handleMessage(defaultTopic, post)

    check:
      proto2.failedPeers.len() == 1
    
    # Start switch with same key as before
    var dialSwitch2 = newStandardSwitch(some(dialKey), addrs = MultiAddress.init("/ip4/127.0.0.1/tcp/65000").tryGet())
    await dialSwitch2.start()
    dialSwitch2.mount(proto)
    
    #Second failure should remove the subscription
    await proto2.handleMessage(defaultTopic, post)
    
    check:
      # Check that subscription works as expected
      (await responseCompletionFuture.withTimeout(3.seconds)) == true
  
    check:
      proto2.failedPeers.len() == 0

    await dialSwitch2.stop()
    await listenSwitch.stop()
