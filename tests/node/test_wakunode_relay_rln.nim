{.used.}

import
  std/[sequtils, tempfiles],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

from std/times import epochTime

import
  ../../../waku/[
    node/waku_node,
    node/peer_manager,
    waku_core,
    waku_node,
    waku_rln_relay,
  ],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, wakunode, testasync, futures],
  ../resources/payloads

proc setupRln(node: WakuNode, identifier: uint) {.async.} =
  await node.mountRlnRelay(
    WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(identifier),
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $identifier),
    )
  )

proc setupRelayWithRln(
    node: WakuNode, identifier: uint, pubsubTopics: seq[string]
) {.async.} =
  await node.mountRelay(pubsubTopics)
  await setupRln(node, identifier)

proc subscribeCompletionHandler(node: WakuNode, pubsubTopic: string): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    if topic == pubsubTopic:
      completionFut.complete(true)

  node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(relayHandler))
  return completionFut

proc sendRlnMessage(
    client: WakuNode,
    pubsubTopic: string,
    contentTopic: string,
    completionFuture: Future[bool],
    payload: seq[byte] = "Hello".toBytes(),
): Future[bool] {.async.} =
  var message = WakuMessage(payload: payload, contentTopic: contentTopic)
  doAssert(client.wakuRlnRelay.appendRLNProof(message, epochTime()).isOk())
  discard await client.publish(some(pubsubTopic), message)
  let isCompleted = await completionFuture.withTimeout(FUTURE_TIMEOUT)
  return isCompleted

proc sendRlnMessageWithInvalidProof(
    client: WakuNode,
    pubsubTopic: string,
    contentTopic: string,
    completionFuture: Future[bool],
    payload: seq[byte] = "Hello".toBytes(),
): Future[bool] {.async.} =
  let
    extraBytes: seq[byte] = @[byte(1), 2, 3]
    rateLimitProofRes =
      client.wakuRlnRelay.groupManager.generateProof(
        concat(payload, extraBytes),
          # we add extra bytes to invalidate proof verification against original payload
        getCurrentEpoch()
      )
    rateLimitProof = rateLimitProofRes.get().encode().buffer
    message =
      WakuMessage(payload: @payload, contentTopic: contentTopic, proof: rateLimitProof)

  discard await client.publish(some(pubsubTopic), message)
  let isCompleted = await completionFuture.withTimeout(FUTURE_TIMEOUT)
  return isCompleted

suite "Waku RlnRelay - End to End":
  var
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic

  var
    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

  var
    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerId {.threadvar.}: PeerId

  asyncSetup:
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())

    serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
    clientPeerId = client.switch.peerInfo.toRemotePeerInfo().peerId

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  suite "Mount":
    asyncTest "Can't mount if relay is not mounted":
      # Given Relay and RLN are not mounted
      check:
        server.wakuRelay == nil
        server.wakuRlnRelay == nil

      # When RlnRelay is mounted
      let
        catchRes =
          catch:
            await server.setupRln(1)

      # Then Relay and RLN are not mounted,and the process fails
      check:
        server.wakuRelay == nil
        server.wakuRlnRelay == nil
        catchRes.error()[].msg ==
          "WakuRelay protocol is not mounted, cannot mount WakuRlnRelay"

    asyncTest "Pubsub topics subscribed before mounting RlnRelay are added to it":
      # Given the node enables Relay and Rln while subscribing to a pubsub topic
      await server.setupRelayWithRln(1.uint, @[pubsubTopic])
      await client.setupRelayWithRln(2.uint, @[pubsubTopic])
      check:
        server.wakuRelay != nil
        server.wakuRlnRelay != nil
        client.wakuRelay != nil
        client.wakuRlnRelay != nil

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # And the node registers the completion handler
      var completionFuture = subscribeCompletionHandler(server, pubsubTopic)

      # When the client sends a valid RLN message
      let
        isCompleted1 =
          await sendRlnMessage(client, pubsubTopic, contentTopic, completionFuture)

      # Then the valid RLN message is relayed
      check:
        isCompleted1
        completionFuture.read()

      # When the client sends an invalid RLN message
      completionFuture = newBoolFuture()
      let
        isCompleted2 =
          await sendRlnMessageWithInvalidProof(
            client, pubsubTopic, contentTopic, completionFuture
          )

      # Then the invalid RLN message is not relayed
      check:
        not isCompleted2

    asyncTest "Pubsub topics subscribed after mounting RlnRelay are added to it":
      # Given the node enables Relay and Rln without subscribing to a pubsub topic
      await server.setupRelayWithRln(1.uint, @[])
      await client.setupRelayWithRln(2.uint, @[])

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # await sleepAsync(FUTURE_TIMEOUT)
      # And the node registers the completion handler
      var completionFuture = subscribeCompletionHandler(server, pubsubTopic)

      await sleepAsync(FUTURE_TIMEOUT)
      # When the client sends a valid RLN message
      let
        isCompleted1 =
          await sendRlnMessage(client, pubsubTopic, contentTopic, completionFuture)

      # Then the valid RLN message is relayed
      check:
        isCompleted1
        completionFuture.read()

      # When the client sends an invalid RLN message
      completionFuture = newBoolFuture()
      let
        isCompleted2 =
          await sendRlnMessageWithInvalidProof(
            client, pubsubTopic, contentTopic, completionFuture
          )

      # Then the invalid RLN message is not relayed
      check:
        not isCompleted2

  suite "Analysis of Bandwith Limitations":
    asyncTest "Valid Payload Sizes":
      # Given the node enables Relay and Rln while subscribing to a pubsub topic
      await server.setupRelayWithRln(1.uint, @[pubsubTopic])
      await client.setupRelayWithRln(2.uint, @[pubsubTopic])

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # Register Relay Handler
      var completionFut = newPushHandlerFuture()
      proc relayHandler(
          topic: PubsubTopic, msg: WakuMessage
      ): Future[void] {.async, gcsafe.} =
        if topic == pubsubTopic:
          completionFut.complete((topic, msg))

      let subscriptionEvent = (kind: PubsubSub, topic: pubsubTopic)
      server.subscribe(subscriptionEvent, some(relayHandler))
      await sleepAsync(FUTURE_TIMEOUT)

      # Generate Messages
      let
        epoch = epochTime()
        payload1b = getByteSequence(1)
        payload1kib = getByteSequence(1024)
        overhead: uint64 = 419
        payload150kib = getByteSequence((150 * 1024) - overhead)
        payload150kibPlus = getByteSequence((150 * 1024) - overhead + 1)

      var
        message1b = WakuMessage(payload: @payload1b, contentTopic: contentTopic)
        message1kib = WakuMessage(payload: @payload1kib, contentTopic: contentTopic)
        message150kib = WakuMessage(payload: @payload150kib, contentTopic: contentTopic)
        message151kibPlus =
          WakuMessage(payload: @payload150kibPlus, contentTopic: contentTopic)

      doAssert(
        client.wakuRlnRelay.appendRLNProof(message1b, epoch + EpochUnitSeconds * 0).isOk()
      )
      doAssert(
        client.wakuRlnRelay.appendRLNProof(message1kib, epoch + EpochUnitSeconds * 1).isOk()
      )
      doAssert(
        client.wakuRlnRelay.appendRLNProof(message150kib, epoch + EpochUnitSeconds * 2).isOk()
      )
      doAssert(
        client.wakuRlnRelay.appendRLNProof(
          message151kibPlus, epoch + EpochUnitSeconds * 3
        ).isOk()
      )

      # When sending the 1B message
      discard await client.publish(some(pubsubTopic), message1b)
      discard await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

      # Then the message is relayed
      check completionFut.read() == (pubsubTopic, message1b)
      # When sending the 1KiB message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message1kib)
      discard await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

      # Then the message is relayed
      check completionFut.read() == (pubsubTopic, message1kib)

      # When sending the 150KiB message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message150kib)
      discard await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

      # Then the message is relayed
      check completionFut.read() == (pubsubTopic, message150kib)

      # When sending the 150KiB plus message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message151kibPlus)

      # Then the message is not relayed
      check not await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

    asyncTest "Invalid Payload Sizes":
      # Given the node enables Relay and Rln while subscribing to a pubsub topic
      await server.setupRelayWithRln(1.uint, @[pubsubTopic])
      await client.setupRelayWithRln(2.uint, @[pubsubTopic])

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # Register Relay Handler
      var completionFut = newPushHandlerFuture()
      proc relayHandler(
          topic: PubsubTopic, msg: WakuMessage
      ): Future[void] {.async, gcsafe.} =
        if topic == pubsubTopic:
          completionFut.complete((topic, msg))

      let subscriptionEvent = (kind: PubsubSub, topic: pubsubTopic)
      server.subscribe(subscriptionEvent, some(relayHandler))
      await sleepAsync(FUTURE_TIMEOUT)

      # Generate Messages
      let
        epoch = epochTime()
        overhead: uint64 = 419
        payload150kibPlus = getByteSequence((150 * 1024) - overhead + 1)

      var
        message151kibPlus =
          WakuMessage(payload: @payload150kibPlus, contentTopic: contentTopic)

      doAssert(
        client.wakuRlnRelay.appendRLNProof(
          message151kibPlus, epoch + EpochUnitSeconds * 3
        )
      )

      # When sending the 150KiB plus message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message151kibPlus)

      # Then the message is not relayed
      check not await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)
