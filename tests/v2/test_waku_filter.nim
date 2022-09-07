{.used.}

import
  std/[options, tables, sets],
  testutils/unittests,
  chronos, 
  chronicles,
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/multistream
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_filter,
  ../test_helpers, 
  ./utils


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")

const dummyHandler = proc(requestId: string, msg: MessagePush) {.async, gcsafe, closure.} = discard

proc newTestSwitch(key=none(PrivateKey), address=none(MultiAddress)): Switch =
  let peerKey = key.get(PrivateKey.random(ECDSA, rng[]).get())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()) 
  return newStandardSwitch(some(peerKey), addrs=peerAddr)


# TODO: Extend test coverage
procSuite "Waku Filter":

  asyncTest "should forward messages to client after subscribed":
    ## Setup
    let rng = crypto.newRng()
    let 
      clientSwitch = newTestSwitch()
      serverSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    # Server
    let
      serverPeerManager = PeerManager.new(serverSwitch) 
      serverProto = WakuFilter.init(serverPeerManager, rng, dummyHandler)
    await serverProto.start()
    serverSwitch.mount(serverProto)

    # Client
    let handlerFuture = newFuture[(string, MessagePush)]()
    proc handler(requestId: string, push: MessagePush) {.async, gcsafe, closure.} =
      handlerFuture.complete((requestId, push))

    let
      clientPeerManager = PeerManager.new(clientSwitch)
      clientProto = WakuFilter.init(clientPeerManager, rng, handler)
    await clientProto.start()
    clientSwitch.mount(clientProto)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## When
    let resSubscription = await clientProto.subscribe(DefaultPubsubTopic, @[DefaultContentTopic])
    require resSubscription.isOk()

    await sleepAsync(5.milliseconds)

    let message = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: DefaultContentTopic)
    await serverProto.handleMessage(DefaultPubsubTopic, message)

    ## Then
    let subscriptionRequestId = resSubscription.get()
    let (requestId, push) = await handlerFuture

    check:
        requestId == subscriptionRequestId
        push.messages == @[message]

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "should not forward messages to client after unsuscribed":
    ## Setup
    let rng = crypto.newRng()
    let 
      clientSwitch = newTestSwitch()
      serverSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    # Server
    let
      serverPeerManager = PeerManager.new(serverSwitch) 
      serverProto = WakuFilter.init(serverPeerManager, rng, dummyHandler)
    await serverProto.start()
    serverSwitch.mount(serverProto)

    # Client
    var handlerFuture = newFuture[void]()
    proc handler(requestId: string, push: MessagePush) {.async, gcsafe, closure.} =
      handlerFuture.complete()

    let
      clientPeerManager = PeerManager.new(clientSwitch)
      clientProto = WakuFilter.init(clientPeerManager, rng, handler)
    await clientProto.start()
    clientSwitch.mount(clientProto)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## Given
    let message = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: DefaultContentTopic)

    let resSubscription = await clientProto.subscribe(DefaultPubsubTopic, @[DefaultContentTopic])
    require resSubscription.isOk()

    await sleepAsync(5.milliseconds)

    await serverProto.handleMessage(DefaultPubsubTopic, message)
    let handlerWasCalledAfterSubscription = await handlerFuture.withTimeout(1.seconds)
    require handlerWasCalledAfterSubscription

    # Reset to test unsubscribe
    handlerFuture = newFuture[void]()

    let resUnsubscription = await clientProto.unsubscribe(DefaultPubsubTopic, @[DefaultContentTopic])
    require resUnsubscription.isOk()

    await sleepAsync(5.milliseconds)

    await serverProto.handleMessage(DefaultPubsubTopic, message)

    ## Then
    let handlerWasCalledAfterUnsubscription = await handlerFuture.withTimeout(1.seconds)
    check:
      not handlerWasCalledAfterUnsubscription
      
    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())
  
  asyncTest "subscription should fail if no filter peer is provided":
    ## Setup
    let clientSwitch = newTestSwitch()
    await clientSwitch.start()

    ## Given
    let clientProto = WakuFilter.init(PeerManager.new(clientSwitch), crypto.newRng(), dummyHandler)
    await clientProto.start()
    clientSwitch.mount(clientProto)

    ## When
    let resSubscription = await clientProto.subscribe(DefaultPubsubTopic, @[DefaultContentTopic])

    ## Then
    check:
      resSubscription.isErr()
      resSubscription.error() == "peer_not_found_failure"

  asyncTest "peer subscription should be dropped if connection fails for second time after the timeout has elapsed":
    ## Setup
    let rng = crypto.newRng()
    let 
      clientSwitch = newTestSwitch()
      serverSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    # Server
    let
      serverPeerManager = PeerManager.new(serverSwitch) 
      serverProto = WakuFilter.init(serverPeerManager, rng, dummyHandler, timeout=1.seconds)
    await serverProto.start()
    serverSwitch.mount(serverProto)

    # Client
    var handlerFuture = newFuture[void]()
    proc handler(requestId: string, push: MessagePush) {.async, gcsafe, closure.} =
      handlerFuture.complete()

    let
      clientPeerManager = PeerManager.new(clientSwitch)
      clientProto = WakuFilter.init(clientPeerManager, rng, handler)
    await clientProto.start()
    clientSwitch.mount(clientProto)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## When
    let resSubscription = await clientProto.subscribe(DefaultPubsubTopic, @[DefaultContentTopic])
    check resSubscription.isOk()

    await sleepAsync(5.milliseconds)

    let message = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: DefaultContentTopic)

    await serverProto.handleMessage(DefaultPubsubTopic, message)
    let handlerShouldHaveBeenCalled = await handlerFuture.withTimeout(1.seconds)
    require handlerShouldHaveBeenCalled

    # Stop client node to test timeout unsubscription
    await clientSwitch.stop()

    await sleepAsync(5.milliseconds)
    
    # First failure should not remove the subscription
    await serverProto.handleMessage(DefaultPubsubTopic, message)
    let 
      subscriptionsBeforeTimeout = serverProto.subscriptions.len()
      failedPeersBeforeTimeout = serverProto.failedPeers.len()
    
    # Wait for peer connection failure timeout to elapse
    await sleepAsync(1.seconds)
    
    #Second failure should remove the subscription
    await serverProto.handleMessage(DefaultPubsubTopic, message)
    let 
      subscriptionsAfterTimeout = serverProto.subscriptions.len()
      failedPeersAfterTimeout = serverProto.failedPeers.len()
    
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
      clientKey = PrivateKey.random(ECDSA, rng[]).get()
      clientAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/65000").get()

    let rng = crypto.newRng()
    let 
      clientSwitch = newTestSwitch(some(clientKey), some(clientAddress))
      serverSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    # Server
    let
      serverPeerManager = PeerManager.new(serverSwitch) 
      serverProto = WakuFilter.init(serverPeerManager, rng, dummyHandler, timeout=2.seconds)
    await serverProto.start()
    serverSwitch.mount(serverProto)

    # Client
    var handlerFuture = newFuture[void]()
    proc handler(requestId: string, push: MessagePush) {.async, gcsafe, closure.} =
      handlerFuture.complete()

    let
      clientPeerManager = PeerManager.new(clientSwitch)
      clientProto = WakuFilter.init(clientPeerManager, rng, handler)
    await clientProto.start()
    clientSwitch.mount(clientProto)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## When
    let message = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: DefaultContentTopic)

    let resSubscription = await clientProto.subscribe(DefaultPubsubTopic, @[DefaultContentTopic])
    check resSubscription.isOk()

    await sleepAsync(5.milliseconds)

    await serverProto.handleMessage(DefaultPubsubTopic, message)
    handlerFuture = newFuture[void]()
      
    let
      subscriptionsBeforeFailure = serverProto.subscriptions.len()
      failedPeersBeforeFailure = serverProto.failedPeers.len()

    # Stop switch to test unsubscribe
    await clientSwitch.stop()

    await sleepAsync(5.milliseconds)
    
    # First failure should add to failure list
    await serverProto.handleMessage(DefaultPubsubTopic, message)
    handlerFuture = newFuture[void]()

    let 
      subscriptionsAfterFailure = serverProto.subscriptions.len()
      failedPeersAfterFailure = serverProto.failedPeers.len()
    
    await sleepAsync(250.milliseconds)

    # Start switch with same key as before
    var clientSwitch2 = newTestSwitch(some(clientKey), some(clientAddress))
    await clientSwitch2.start()
    await clientProto.start()
    clientSwitch2.mount(clientProto)
    
    # If push succeeds after failure, the peer should removed from failed peers list
    await serverProto.handleMessage(DefaultPubsubTopic, message)
    let handlerShouldHaveBeenCalled = await handlerFuture.withTimeout(1.seconds)
    
    let 
      subscriptionsAfterSuccessfulConnection = serverProto.subscriptions.len()
      failedPeersAfterSuccessfulConnection = serverProto.failedPeers.len()

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
