{.used.}

import
  std/[options, tables],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_filter/client,
  ./utils,
  ./testlib/common,
  ./testlib/switch


proc newTestWakuFilterNode(switch: Switch, timeout: Duration = 2.hours): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuFilter.new(peerManager, rng, timeout)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuFilterClient(switch: Switch): Future[WakuFilterClient] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuFilterClient.new(peerManager, rng)

  await proto.start()
  switch.mount(proto)

  return proto


# TODO: Extend test coverage
suite "Waku Filter":
  asyncTest "should forward messages to client after subscribed":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let 
      server = await newTestWakuFilterNode(serverSwitch)
      client = await newTestWakuFilterClient(clientSwitch)

    ## Given
    let serverAddr = serverSwitch.peerInfo.toRemotePeerInfo()
    
    let pushHandlerFuture = newFuture[(string, WakuMessage)]()
    proc pushHandler(pubsubTopic: PubsubTopic, message: WakuMessage) {.gcsafe, closure.} =
      pushHandlerFuture.complete((pubsubTopic, message))

    let 
      pubsubTopic = DefaultPubsubTopic
      contentTopic = "test-content-topic"
      msg = fakeWakuMessage(contentTopic=contentTopic)

    ## When
    require (await client.subscribe(pubsubTopic, contentTopic, pushHandler, peer=serverAddr)).isOk()

    # WARN: Sleep necessary to avoid a race condition between the subscription and the handle message proc
    await sleepAsync(5.milliseconds)

    await server.handleMessage(pubsubTopic, msg)

    require await pushHandlerFuture.withTimeout(5.seconds)

    ## Then
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == pubsubTopic
      pushedMsg == msg

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "should not forward messages to client after unsuscribed":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())
    
    let 
      server = await newTestWakuFilterNode(serverSwitch)
      client = await newTestWakuFilterClient(clientSwitch)

    ## Given
    let serverAddr = serverSwitch.peerInfo.toRemotePeerInfo()

    var pushHandlerFuture = newFuture[void]()
    proc pushHandler(pubsubTopic: PubsubTopic, message: WakuMessage) {.gcsafe, closure.} =
      pushHandlerFuture.complete()

    let 
      pubsubTopic = DefaultPubsubTopic
      contentTopic = "test-content-topic"
      msg = fakeWakuMessage(contentTopic=contentTopic)

    ## When
    require (await client.subscribe(pubsubTopic, contentTopic, pushHandler, peer=serverAddr)).isOk()

    # WARN: Sleep necessary to avoid a race condition between the subscription and the handle message proc
    await sleepAsync(5.milliseconds)

    await server.handleMessage(pubsubTopic, msg)

    require await pushHandlerFuture.withTimeout(1.seconds)

    # Reset to test unsubscribe
    pushHandlerFuture = newFuture[void]()

    require (await client.unsubscribe(pubsubTopic, contentTopic, peer=serverAddr)).isOk()

    # WARN: Sleep necessary to avoid a race condition between the unsubscription and the handle message proc
    await sleepAsync(5.milliseconds)

    await server.handleMessage(pubsubTopic, msg)

    ## Then
    let handlerWasCalledAfterUnsubscription = await pushHandlerFuture.withTimeout(1.seconds)
    check:
      not handlerWasCalledAfterUnsubscription
      
    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "peer subscription should be dropped if connection fails for second time after the timeout has elapsed":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuFilterNode(serverSwitch, timeout=200.milliseconds)
      client = await newTestWakuFilterClient(clientSwitch)

    ## Given
    let serverAddr = serverSwitch.peerInfo.toRemotePeerInfo()

    var pushHandlerFuture = newFuture[void]()
    proc pushHandler(pubsubTopic: PubsubTopic, message: WakuMessage) {.gcsafe, closure.} =
      pushHandlerFuture.complete()

    let 
      pubsubTopic = DefaultPubsubTopic
      contentTopic = "test-content-topic"
      msg = fakeWakuMessage(contentTopic=contentTopic)

    ## When
    require (await client.subscribe(pubsubTopic, contentTopic, pushHandler, peer=serverAddr)).isOk()

    # WARN: Sleep necessary to avoid a race condition between the unsubscription and the handle message proc
    await sleepAsync(5.milliseconds)

    await server.handleMessage(DefaultPubsubTopic, msg)
    
    # Push handler should be called
    require await pushHandlerFuture.withTimeout(1.seconds)

    # Stop client node to test timeout unsubscription
    await clientSwitch.stop()

    await sleepAsync(5.milliseconds)
    
    # First failure should not remove the subscription
    await server.handleMessage(DefaultPubsubTopic, msg)
    let 
      subscriptionsBeforeTimeout = server.subscriptions.len()
      failedPeersBeforeTimeout = server.failedPeers.len()
    
    # Wait for the configured peer connection timeout to elapse (200ms)
    await sleepAsync(200.milliseconds)
    
    # Second failure should remove the subscription
    await server.handleMessage(DefaultPubsubTopic, msg)
    let 
      subscriptionsAfterTimeout = server.subscriptions.len()
      failedPeersAfterTimeout = server.failedPeers.len()
    
    ## Then
    check:
      subscriptionsBeforeTimeout == 1
      failedPeersBeforeTimeout == 1
      subscriptionsAfterTimeout == 0
      failedPeersAfterTimeout == 0
  
    ## Cleanup
    await serverSwitch.stop()

  asyncTest "peer subscription should not be dropped if connection recovers before timeout elapses":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuFilterNode(serverSwitch, timeout=200.milliseconds)
      client = await newTestWakuFilterClient(clientSwitch)

    ## Given
    let serverAddr = serverSwitch.peerInfo.toRemotePeerInfo()

    var pushHandlerFuture = newFuture[void]()
    proc pushHandler(pubsubTopic: PubsubTopic, message: WakuMessage) {.gcsafe, closure.} =
      pushHandlerFuture.complete()

    let 
      pubsubTopic = DefaultPubsubTopic
      contentTopic = "test-content-topic"
      msg = fakeWakuMessage(contentTopic=contentTopic)

    ## When
    require (await client.subscribe(pubsubTopic, contentTopic, pushHandler, peer=serverAddr)).isOk()

    # WARN: Sleep necessary to avoid a race condition between the unsubscription and the handle message proc
    await sleepAsync(5.milliseconds)

    await server.handleMessage(DefaultPubsubTopic, msg)
    
    # Push handler should be called
    require await pushHandlerFuture.withTimeout(1.seconds)
    
    let
      subscriptionsBeforeFailure = server.subscriptions.len()
      failedPeersBeforeFailure = server.failedPeers.len()

    # Stop switch to test unsubscribe
    await clientSwitch.stop()

    await sleepAsync(5.milliseconds)
    
    # First failure should add to failure list
    await server.handleMessage(DefaultPubsubTopic, msg)
    
    pushHandlerFuture = newFuture[void]()

    let 
      subscriptionsAfterFailure = server.subscriptions.len()
      failedPeersAfterFailure = server.failedPeers.len()
    
    await sleepAsync(100.milliseconds)
    
    # Start switch with same key as before
    let clientSwitch2 = newTestSwitch(
      some(clientSwitch.peerInfo.privateKey),
      some(clientSwitch.peerInfo.addrs[0])
    )
    await clientSwitch2.start()
    await client.start()
    clientSwitch2.mount(client)
    
    # If push succeeds after failure, the peer should removed from failed peers list
    await server.handleMessage(DefaultPubsubTopic, msg)
    let handlerShouldHaveBeenCalled = await pushHandlerFuture.withTimeout(1.seconds)

    let 
      subscriptionsAfterSuccessfulConnection = server.subscriptions.len()
      failedPeersAfterSuccessfulConnection = server.failedPeers.len()
    
    ## Then
    check:
      handlerShouldHaveBeenCalled

    check:
      subscriptionsBeforeFailure == 1
      subscriptionsAfterFailure == 1
      subscriptionsAfterSuccessfulConnection == 1

    check:
      failedPeersBeforeFailure == 0
      failedPeersAfterFailure == 1
      failedPeersAfterSuccessfulConnection == 0
  
    ## Cleanup
    await allFutures(clientSwitch2.stop(), serverSwitch.stop())
