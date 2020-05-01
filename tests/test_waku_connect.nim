#
#                   Waku
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import
  sequtils, tables, unittest, chronos, eth/[keys, p2p], eth/p2p/peer_pool,
  ../waku/protocol/v1/waku_protocol,
  ./test_helpers

const
  safeTTL = 5'u32
  waitInterval = messageInterval + 150.milliseconds
  conditionTimeoutMs = 3000

# check on a condition until true or return a future containing false
# if timeout expires first
proc eventually(timeout: int, condition: proc(): bool {.gcsafe.}): Future[bool] =
  let wrappedCondition = proc(): Future[bool] {.async.} =
    let f = newFuture[bool]()
    while not condition():
      await sleepAsync(100.milliseconds)
    f.complete(true)
    return await f
  return withTimeout(wrappedCondition(), timeout)

# TODO: Just repeat all the test_shh_connect tests here that are applicable or
# have some commonly shared test code for both protocols.
suite "Waku connections":
  asyncTest "Waku connections":
    var
      n1 = setupTestNode(Waku)
      n2 = setupTestNode(Waku)
      n3 = setupTestNode(Waku)
      n4 = setupTestNode(Waku)

    var topics: seq[Topic]
    n1.protocolState(Waku).config.topics = some(topics)
    n2.protocolState(Waku).config.topics = some(topics)
    n3.protocolState(Waku).config.topics = none(seq[Topic])
    n4.protocolState(Waku).config.topics = none(seq[Topic])

    n1.startListening()
    n3.startListening()

    let
      p1 = await n2.rlpxConnect(newNode(n1.toENode()))
      p2 = await n2.rlpxConnect(newNode(n3.toENode()))
      p3 = await n4.rlpxConnect(newNode(n3.toENode()))
    check:
      p1.isNil
      p2.isNil == false
      p3.isNil == false

  asyncTest "Waku set-topic-interest":
    var
      wakuTopicNode = setupTestNode(Waku)
      wakuNode = setupTestNode(Waku)

    let
      topic1 = [byte 0xDA, 0xDA, 0xDA, 0xAA]
      topic2 = [byte 0xD0, 0xD0, 0xD0, 0x00]
      wrongTopic = [byte 0x4B, 0x1D, 0x4B, 0x1D]

    # Set one topic so we are not considered a full node
    wakuTopicNode.protocolState(Waku).config.topics = some(@[topic1])

    wakuNode.startListening()
    await wakuTopicNode.peerPool.connectToNode(newNode(wakuNode.toENode()))

    # Update topic interest
    check:
      await setTopicInterest(wakuTopicNode, @[topic1, topic2])

    let payload = repeat(byte 0, 10)
    check:
      wakuNode.postMessage(ttl = safeTTL, topic = topic1, payload = payload)
      wakuNode.postMessage(ttl = safeTTL, topic = topic2, payload = payload)
      wakuNode.postMessage(ttl = safeTTL, topic = wrongTopic, payload = payload)
      wakuNode.protocolState(Waku).queue.items.len == 3
    await sleepAsync(waitInterval)
    check:
      wakuTopicNode.protocolState(Waku).queue.items.len == 2

  asyncTest "Waku set-minimum-pow":
    var
      wakuPowNode = setupTestNode(Waku)
      wakuNode = setupTestNode(Waku)

    wakuNode.startListening()
    await wakuPowNode.peerPool.connectToNode(newNode(wakuNode.toENode()))

    # Update minimum pow
    await setPowRequirement(wakuPowNode, 1.0)
    await sleepAsync(waitInterval)

    check:
      wakuNode.peerPool.len == 1

    # check powRequirement is updated
    for peer in wakuNode.peerPool.peers:
      check:
        peer.state(Waku).powRequirement == 1.0

  asyncTest "Waku set-light-node":
    var
      wakuLightNode = setupTestNode(Waku)
      wakuNode = setupTestNode(Waku)

    wakuNode.startListening()
    await wakuLightNode.peerPool.connectToNode(newNode(wakuNode.toENode()))

    # Update minimum pow
    await setLightNode(wakuLightNode, true)
    await sleepAsync(waitInterval)

    check:
      wakuNode.peerPool.len == 1

    # check lightNode is updated
    for peer in wakuNode.peerPool.peers:
      check:
        peer.state(Waku).isLightNode

  asyncTest "Waku set-bloom-filter":
    var
      wakuBloomNode = setupTestNode(Waku)
      wakuNode = setupTestNode(Waku)
      bloom = fullBloom()
      topics = @[[byte 0xDA, 0xDA, 0xDA, 0xAA]]

    # Set topic interest
    discard await wakuBloomNode.setTopicInterest(topics)

    wakuBloomNode.startListening()
    await wakuNode.peerPool.connectToNode(newNode(wakuBloomNode.toENode()))

    # Sanity check
    check:
      wakuNode.peerPool.len == 1

    # check bloom filter is updated
    for peer in wakuNode.peerPool.peers:
      check:
        peer.state(Waku).bloom == bloom
        peer.state(Waku).topics == some(topics)

    let hasBloomNodeConnectedCondition = proc(): bool = wakuBloomNode.peerPool.len == 1
    # wait for the peer to be connected on the other side
    let hasBloomNodeConnected = await eventually(conditionTimeoutMs, hasBloomNodeConnectedCondition)
    # check bloom filter is updated
    check:
      hasBloomNodeConnected

    # disable one bit in the bloom filter
    bloom[0] = 0x0

    # and set it
    await setBloomFilter(wakuBloomNode, bloom)

    let bloomFilterUpdatedCondition = proc(): bool =
      for peer in wakuNode.peerPool.peers:
        return peer.state(Waku).bloom == bloom and peer.state(Waku).topics == none(seq[Topic])

    let bloomFilterUpdated = await eventually(conditionTimeoutMs, bloomFilterUpdatedCondition)
    # check bloom filter is updated
    check:
      bloomFilterUpdated

  asyncTest "Waku topic-interest":
    var
      wakuTopicNode = setupTestNode(Waku)
      wakuNode = setupTestNode(Waku)

    let
      topic1 = [byte 0xDA, 0xDA, 0xDA, 0xAA]
      topic2 = [byte 0xD0, 0xD0, 0xD0, 0x00]
      wrongTopic = [byte 0x4B, 0x1D, 0x4B, 0x1D]

    wakuTopicNode.protocolState(Waku).config.topics = some(@[topic1, topic2])

    wakuNode.startListening()
    await wakuTopicNode.peerPool.connectToNode(newNode(wakuNode.toENode()))

    let payload = repeat(byte 0, 10)
    check:
      wakuNode.postMessage(ttl = safeTTL, topic = topic1, payload = payload)
      wakuNode.postMessage(ttl = safeTTL, topic = topic2, payload = payload)
      wakuNode.postMessage(ttl = safeTTL, topic = wrongTopic, payload = payload)
      wakuNode.protocolState(Waku).queue.items.len == 3

    let response = await eventually(conditionTimeoutMs, proc (): bool = wakuTopicNode.protocolState(Waku).queue.items.len == 2)
    check:
      response

  asyncTest "Waku topic-interest versus bloom filter":
    var
      wakuTopicNode = setupTestNode(Waku)
      wakuNode = setupTestNode(Waku)

    let
      topic1 = [byte 0xDA, 0xDA, 0xDA, 0xAA]
      topic2 = [byte 0xD0, 0xD0, 0xD0, 0x00]
      bloomTopic = [byte 0x4B, 0x1D, 0x4B, 0x1D]

    # It was checked that the topics don't trigger false positives on the bloom.
    wakuTopicNode.protocolState(Waku).config.topics = some(@[topic1, topic2])
    wakuTopicNode.protocolState(Waku).config.bloom = some(toBloom([bloomTopic]))

    wakuNode.startListening()
    await wakuTopicNode.peerPool.connectToNode(newNode(wakuNode.toENode()))

    let payload = repeat(byte 0, 10)
    check:
      wakuNode.postMessage(ttl = safeTTL, topic = topic1, payload = payload)
      wakuNode.postMessage(ttl = safeTTL, topic = topic2, payload = payload)
      wakuNode.postMessage(ttl = safeTTL, topic = bloomTopic, payload = payload)
      wakuNode.protocolState(Waku).queue.items.len == 3
    await sleepAsync(waitInterval)
    check:
      wakuTopicNode.protocolState(Waku).queue.items.len == 2

  asyncTest "Light node posting":
    var ln = setupTestNode(Waku)
    await ln.setLightNode(true)
    var fn = setupTestNode(Waku)
    fn.startListening()
    await ln.peerPool.connectToNode(newNode(fn.toENode()))

    let topic = [byte 0, 0, 0, 0]

    check:
      ln.peerPool.connectedNodes.len() == 1
      # normal post
      ln.postMessage(ttl = safeTTL, topic = topic,
                      payload = repeat(byte 0, 10)) == true
      ln.protocolState(Waku).queue.items.len == 1
      # TODO: add test on message relaying
