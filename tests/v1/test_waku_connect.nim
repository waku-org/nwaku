#
#                   Waku
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)
{.used.}

import
  std/[sequtils, tables],
  chronos, testutils/unittests, eth/[keys, p2p], eth/p2p/peer_pool,
  ../../waku/v1/protocol/waku_protocol,
  ../test_helpers

const
  safeTTL = 5'u32
  waitInterval = messageInterval + 150.milliseconds
  conditionTimeoutMs = 3000.milliseconds

proc resetMessageQueues(nodes: varargs[EthereumNode]) =
  for node in nodes:
    node.resetMessageQueue()

# check on a condition until true or return a future containing false
# if timeout expires first
proc eventually(timeout: Duration,
    condition: proc(): bool {.gcsafe, raises: [Defect].}): Future[bool] =
  let wrappedCondition = proc(): Future[bool] {.async.} =
    let f = newFuture[bool]()
    while not condition():
      await sleepAsync(100.milliseconds)
    f.complete(true)
    return await f
  return withTimeout(wrappedCondition(), timeout)

procSuite "Waku connections":
  let rng = keys.newRng()
  asyncTest "Waku connections":
    var
      n1 = setupTestNode(rng, Waku)
      n2 = setupTestNode(rng, Waku)
      n3 = setupTestNode(rng, Waku)
      n4 = setupTestNode(rng, Waku)

    var topics: seq[waku_protocol.Topic]
    n1.protocolState(Waku).config.topics = some(topics)
    n2.protocolState(Waku).config.topics = some(topics)
    n3.protocolState(Waku).config.topics = none(seq[waku_protocol.Topic])
    n4.protocolState(Waku).config.topics = none(seq[waku_protocol.Topic])

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

  asyncTest "Filters with encryption and signing":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let encryptKeyPair = KeyPair.random(rng[])
    let signKeyPair = KeyPair.random(rng[])
    var symKey: SymKey
    let topic = [byte 0x12, 0, 0, 0]
    var filters: seq[string] = @[]
    var payloads = [repeat(byte 1, 10), repeat(byte 2, 10),
                    repeat(byte 3, 10), repeat(byte 4, 10)]
    var futures = [newFuture[int](), newFuture[int](),
                   newFuture[int](), newFuture[int]()]

    proc handler1(msg: ReceivedMessage) =
      var count {.global.}: int
      check msg.decoded.payload == payloads[0] or
        msg.decoded.payload == payloads[1]
      count += 1
      if count == 2: futures[0].complete(1)
    proc handler2(msg: ReceivedMessage) =
      check msg.decoded.payload == payloads[1]
      futures[1].complete(1)
    proc handler3(msg: ReceivedMessage) =
      var count {.global.}: int
      check msg.decoded.payload == payloads[2] or
        msg.decoded.payload == payloads[3]
      count += 1
      if count == 2: futures[2].complete(1)
    proc handler4(msg: ReceivedMessage) =
      check msg.decoded.payload == payloads[3]
      futures[3].complete(1)

    # Filters
    # filter for encrypted asym
    filters.add(node1.subscribeFilter(initFilter(
      privateKey = some(encryptKeyPair.seckey), topics = @[topic]), handler1))
    # filter for encrypted asym + signed
    filters.add(node1.subscribeFilter(initFilter(some(signKeyPair.pubkey),
      privateKey = some(encryptKeyPair.seckey), topics = @[topic]), handler2))
    # filter for encrypted sym
    filters.add(node1.subscribeFilter(initFilter(symKey = some(symKey),
      topics = @[topic]), handler3))
    # filter for encrypted sym + signed
    filters.add(node1.subscribeFilter(initFilter(some(signKeyPair.pubkey),
      symKey = some(symKey), topics = @[topic]), handler4))
    # Messages
    check:
      # encrypted asym
      node2.postMessage(some(encryptKeyPair.pubkey), ttl = safeTTL,
                        topic = topic, payload = payloads[0]) == true
      # encrypted asym + signed
      node2.postMessage(some(encryptKeyPair.pubkey),
                        src = some(signKeyPair.seckey), ttl = safeTTL,
                        topic = topic, payload = payloads[1]) == true
      # encrypted sym
      node2.postMessage(symKey = some(symKey), ttl = safeTTL, topic = topic,
                        payload = payloads[2]) == true
      # encrypted sym + signed
      node2.postMessage(symKey = some(symKey),
                        src = some(signKeyPair.seckey),
                        ttl = safeTTL, topic = topic,
                        payload = payloads[3]) == true

      node2.protocolState(Waku).queue.items.len == 4

    check:
      await allFutures(futures).withTimeout(waitInterval)
      node1.protocolState(Waku).queue.items.len == 4

    for filter in filters:
      check node1.unsubscribeFilter(filter) == true

  asyncTest "Filters with topics":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic1 = [byte 0x12, 0, 0, 0]
    let topic2 = [byte 0x34, 0, 0, 0]
    var payloads = [repeat(byte 0, 10), repeat(byte 1, 10)]
    var futures = [newFuture[int](), newFuture[int]()]
    proc handler1(msg: ReceivedMessage) =
      check msg.decoded.payload == payloads[0]
      futures[0].complete(1)
    proc handler2(msg: ReceivedMessage) =
      check msg.decoded.payload == payloads[1]
      futures[1].complete(1)

    var filter1 = node1.subscribeFilter(initFilter(topics = @[topic1]), handler1)
    var filter2 = node1.subscribeFilter(initFilter(topics = @[topic2]), handler2)

    check:
      node2.postMessage(ttl = safeTTL + 1, topic = topic1,
                        payload = payloads[0]) == true
      node2.postMessage(ttl = safeTTL, topic = topic2,
                        payload = payloads[1]) == true
      node2.protocolState(Waku).queue.items.len == 2

      await allFutures(futures).withTimeout(waitInterval)
      node1.protocolState(Waku).queue.items.len == 2

      node1.unsubscribeFilter(filter1) == true
      node1.unsubscribeFilter(filter2) == true

  asyncTest "Filters with PoW":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0x12, 0, 0, 0]
    var payload = repeat(byte 0, 10)
    var futures = [newFuture[int](), newFuture[int]()]
    proc handler1(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      futures[0].complete(1)
    proc handler2(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      futures[1].complete(1)

    var filter1 = node1.subscribeFilter(
      initFilter(topics = @[topic], powReq = 0), handler1)
    var filter2 = node1.subscribeFilter(
      initFilter(topics = @[topic], powReq = 1_000_000), handler2)

    check:
      node2.postMessage(ttl = safeTTL, topic = topic, payload = payload) == true

      (await futures[0].withTimeout(waitInterval)) == true
      (await futures[1].withTimeout(waitInterval)) == false
      node1.protocolState(Waku).queue.items.len == 1

      node1.unsubscribeFilter(filter1) == true
      node1.unsubscribeFilter(filter2) == true

  asyncTest "Filters with queues":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0, 0, 0, 0]
    let payload = repeat(byte 0, 10)

    var filter = node1.subscribeFilter(initFilter(topics = @[topic]))
    for i in countdown(10, 1):
      check node2.postMessage(ttl = safeTTL, topic = topic,
                              payload = payload) == true

    await sleepAsync(waitInterval)
    check:
      node1.getFilterMessages(filter).len() == 10
      node1.getFilterMessages(filter).len() == 0
      node1.unsubscribeFilter(filter) == true

  asyncTest "Local filter notify":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0, 0, 0, 0]

    var filter = node1.subscribeFilter(initFilter(topics = @[topic]))
    check:
      node1.postMessage(ttl = safeTTL, topic = topic,
                        payload = repeat(byte 4, 10)) == true
      node1.getFilterMessages(filter).len() == 1
      node1.unsubscribeFilter(filter) == true

  asyncTest "Bloomfilter blocking":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let sendTopic1 = [byte 0x12, 0, 0, 0]
    let sendTopic2 = [byte 0x34, 0, 0, 0]
    let filterTopics = @[[byte 0x34, 0, 0, 0],[byte 0x56, 0, 0, 0]]
    let payload = repeat(byte 0, 10)
    var f: Future[int] = newFuture[int]()
    proc handler(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      f.complete(1)
    var filter = node1.subscribeFilter(
      initFilter(topics = filterTopics), handler)
    await node1.setBloomFilter(node1.filtersToBloom())

    check:
      node2.postMessage(ttl = safeTTL, topic = sendTopic1,
                        payload = payload) == true
      node2.protocolState(Waku).queue.items.len == 1

      (await f.withTimeout(waitInterval)) == false
      node1.protocolState(Waku).queue.items.len == 0

    resetMessageQueues(node1, node2)

    f = newFuture[int]()

    check:
      node2.postMessage(ttl = safeTTL, topic = sendTopic2,
                        payload = payload) == true
      node2.protocolState(Waku).queue.items.len == 1

      await f.withTimeout(waitInterval)
      f.read() == 1
      node1.protocolState(Waku).queue.items.len == 1

      node1.unsubscribeFilter(filter) == true

    await node1.setBloomFilter(fullBloom())

  asyncTest "PoW blocking":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0, 0, 0, 0]
    let payload = repeat(byte 0, 10)

    await node1.setPowRequirement(1_000_000)
    check:
      node2.postMessage(ttl = safeTTL, topic = topic, payload = payload) == true
      node2.protocolState(Waku).queue.items.len == 1
    await sleepAsync(waitInterval)
    check:
      node1.protocolState(Waku).queue.items.len == 0

    resetMessageQueues(node1, node2)

    await node1.setPowRequirement(0.0)
    check:
      node2.postMessage(ttl = safeTTL, topic = topic, payload = payload) == true
      node2.protocolState(Waku).queue.items.len == 1
    await sleepAsync(waitInterval)
    check:
      node1.protocolState(Waku).queue.items.len == 1

  asyncTest "Queue pruning":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0, 0, 0, 0]
    let payload = repeat(byte 0, 10)
    # We need a minimum TTL of 2 as when set to 1 there is a small chance that
    # it is already expired after messageInterval due to rounding down of float
    # to uint32 in postMessage()
    let lowerTTL = 2'u32 # Lower TTL as we need to wait for messages to expire
    for i in countdown(10, 1):
      check node2.postMessage(ttl = lowerTTL, topic = topic, payload = payload)
    check node2.protocolState(Waku).queue.items.len == 10

    await sleepAsync(waitInterval)
    check node1.protocolState(Waku).queue.items.len == 10

    await sleepAsync(milliseconds((lowerTTL+1)*1000))
    check node1.protocolState(Waku).queue.items.len == 0
    check node2.protocolState(Waku).queue.items.len == 0

  asyncTest "P2P post":
    var node1 = setupTestNode(rng, Waku)
    var node2 = setupTestNode(rng, Waku)
    node2.startListening()
    waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0, 0, 0, 0]
    var f: Future[int] = newFuture[int]()
    proc handler(msg: ReceivedMessage) =
      check msg.decoded.payload == repeat(byte 4, 10)
      f.complete(1)

    var filter = node1.subscribeFilter(initFilter(topics = @[topic],
                                       allowP2P = true), handler)
    # Need to be sure that node1 is added in the peerpool of node2 as
    # postMessage with target will iterate over the peers
    require await eventually(conditionTimeoutMs,
      proc(): bool = node2.peerPool.len == 1)
    check:
      node1.setPeerTrusted(toNodeId(node2.keys.pubkey)) == true
      node2.postMessage(ttl = 10, topic = topic,
                        payload = repeat(byte 4, 10),
                        targetPeer = some(toNodeId(node1.keys.pubkey))) == true

      await f.withTimeout(waitInterval)
      f.read() == 1
      node1.protocolState(Waku).queue.items.len == 0
      node2.protocolState(Waku).queue.items.len == 0

      node1.unsubscribeFilter(filter) == true

  asyncTest "Light node posting":
    var ln = setupTestNode(rng, Waku)
    await ln.setLightNode(true)
    var fn = setupTestNode(rng, Waku)
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

  asyncTest "Connect two light nodes":
    var ln1 = setupTestNode(rng, Waku)
    var ln2 = setupTestNode(rng, Waku)

    await ln1.setLightNode(true)
    await ln2.setLightNode(true)

    ln2.startListening()
    let peer = await ln1.rlpxConnect(newNode(ln2.toENode()))
    check peer.isNil == true

  asyncTest "Waku set-topic-interest":
    var
      wakuTopicNode = setupTestNode(rng, Waku)
      wakuNode = setupTestNode(rng, Waku)

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
      wakuPowNode = setupTestNode(rng, Waku)
      wakuNode = setupTestNode(rng, Waku)

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
      wakuLightNode = setupTestNode(rng, Waku)
      wakuNode = setupTestNode(rng, Waku)

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
      wakuBloomNode = setupTestNode(rng, Waku)
      wakuNode = setupTestNode(rng, Waku)
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

    let hasBloomNodeConnectedCondition = proc(): bool =
      wakuBloomNode.peerPool.len == 1
    # wait for the peer to be connected on the other side
    let hasBloomNodeConnected =
      await eventually(conditionTimeoutMs, hasBloomNodeConnectedCondition)
    # check bloom filter is updated
    check:
      hasBloomNodeConnected

    # disable one bit in the bloom filter
    bloom[0] = 0x0

    # and set it
    await setBloomFilter(wakuBloomNode, bloom)

    let bloomFilterUpdatedCondition = proc(): bool =
      for peer in wakuNode.peerPool.peers:
        return peer.state(Waku).bloom == bloom and
          peer.state(Waku).topics == none(seq[waku_protocol.Topic])

    let bloomFilterUpdated =
      await eventually(conditionTimeoutMs, bloomFilterUpdatedCondition)
    # check bloom filter is updated
    check:
      bloomFilterUpdated

  asyncTest "Waku topic-interest":
    var
      wakuTopicNode = setupTestNode(rng, Waku)
      wakuNode = setupTestNode(rng, Waku)

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

      await eventually(conditionTimeoutMs,
        proc (): bool = wakuTopicNode.protocolState(Waku).queue.items.len == 2)

  asyncTest "Waku topic-interest versus bloom filter":
    var
      wakuTopicNode = setupTestNode(rng, Waku)
      wakuNode = setupTestNode(rng, Waku)

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
