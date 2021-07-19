#
#                 Ethereum P2P
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

{.used.}

import
  std/[sequtils, options, tables],
  chronos, testutils/unittests, bearssl,
  ../../eth/[keys, p2p], ../../eth/p2p/peer_pool,
  ../../eth/p2p/rlpx_protocols/whisper_protocol,
  ./p2p_test_helper

proc resetMessageQueues(nodes: varargs[EthereumNode]) =
  for node in nodes:
    node.resetMessageQueue()

let safeTTL = 5'u32
let waitInterval = messageInterval + 150.milliseconds

procSuite "Whisper connections":
  let rng = newRng()
  var node1 = setupTestNode(rng, Whisper)
  var node2 = setupTestNode(rng, Whisper)
  node2.startListening()
  waitFor node1.peerPool.connectToNode(newNode(node2.toENode()))
  asyncTest "Two peers connected":
    check:
      node1.peerPool.connectedNodes.len() == 1

  asyncTest "Filters with encryption and signing":
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
      check msg.decoded.payload == payloads[0] or msg.decoded.payload == payloads[1]
      count += 1
      if count == 2: futures[0].complete(1)
    proc handler2(msg: ReceivedMessage) =
      check msg.decoded.payload == payloads[1]
      futures[1].complete(1)
    proc handler3(msg: ReceivedMessage) =
      var count {.global.}: int
      check msg.decoded.payload == payloads[2] or msg.decoded.payload == payloads[3]
      count += 1
      if count == 2: futures[2].complete(1)
    proc handler4(msg: ReceivedMessage) =
      check msg.decoded.payload == payloads[3]
      futures[3].complete(1)

    # Filters
    # filter for encrypted asym
    filters.add(node1.subscribeFilter(initFilter(privateKey = some(encryptKeyPair.seckey),
                                                topics = @[topic]), handler1))
    # filter for encrypted asym + signed
    filters.add(node1.subscribeFilter(initFilter(some(signKeyPair.pubkey),
                                                privateKey = some(encryptKeyPair.seckey),
                                                topics = @[topic]), handler2))
    # filter for encrypted sym
    filters.add(node1.subscribeFilter(initFilter(symKey = some(symKey),
                                                topics = @[topic]), handler3))
    # filter for encrypted sym + signed
    filters.add(node1.subscribeFilter(initFilter(some(signKeyPair.pubkey),
                                                symKey = some(symKey),
                                                topics = @[topic]), handler4))
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

      node2.protocolState(Whisper).queue.items.len == 4

    check:
      await allFutures(futures).withTimeout(waitInterval)
      node1.protocolState(Whisper).queue.items.len == 4

    for filter in filters:
      check node1.unsubscribeFilter(filter) == true

    resetMessageQueues(node1, node2)

  asyncTest "Filters with topics":
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
      node2.protocolState(Whisper).queue.items.len == 2

      await allFutures(futures).withTimeout(waitInterval)
      node1.protocolState(Whisper).queue.items.len == 2

      node1.unsubscribeFilter(filter1) == true
      node1.unsubscribeFilter(filter2) == true

    resetMessageQueues(node1, node2)

  asyncTest "Filters with PoW":
    let topic = [byte 0x12, 0, 0, 0]
    var payload = repeat(byte 0, 10)
    var futures = [newFuture[int](), newFuture[int]()]
    proc handler1(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      futures[0].complete(1)
    proc handler2(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      futures[1].complete(1)

    var filter1 = node1.subscribeFilter(initFilter(topics = @[topic], powReq = 0),
                                        handler1)
    var filter2 = node1.subscribeFilter(initFilter(topics = @[topic],
                                        powReq = 1_000_000), handler2)

    check:
      node2.postMessage(ttl = safeTTL, topic = topic, payload = payload) == true

      (await futures[0].withTimeout(waitInterval)) == true
      (await futures[1].withTimeout(waitInterval)) == false
      node1.protocolState(Whisper).queue.items.len == 1

      node1.unsubscribeFilter(filter1) == true
      node1.unsubscribeFilter(filter2) == true

    resetMessageQueues(node1, node2)

  asyncTest "Filters with queues":
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

    resetMessageQueues(node1, node2)

  asyncTest "Local filter notify":
    let topic = [byte 0, 0, 0, 0]

    var filter = node1.subscribeFilter(initFilter(topics = @[topic]))
    check:
      node1.postMessage(ttl = safeTTL, topic = topic,
                        payload = repeat(byte 4, 10)) == true
      node1.getFilterMessages(filter).len() == 1
      node1.unsubscribeFilter(filter) == true

    await sleepAsync(waitInterval)
    resetMessageQueues(node1, node2)

  asyncTest "Bloomfilter blocking":
    let sendTopic1 = [byte 0x12, 0, 0, 0]
    let sendTopic2 = [byte 0x34, 0, 0, 0]
    let filterTopics = @[[byte 0x34, 0, 0, 0],[byte 0x56, 0, 0, 0]]
    let payload = repeat(byte 0, 10)
    var f: Future[int] = newFuture[int]()
    proc handler(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      f.complete(1)
    var filter = node1.subscribeFilter(initFilter(topics = filterTopics), handler)
    await node1.setBloomFilter(node1.filtersToBloom())

    check:
      node2.postMessage(ttl = safeTTL, topic = sendTopic1,
                        payload = payload) == true
      node2.protocolState(Whisper).queue.items.len == 1

      (await f.withTimeout(waitInterval)) == false
      node1.protocolState(Whisper).queue.items.len == 0

    resetMessageQueues(node1, node2)

    f = newFuture[int]()

    check:
      node2.postMessage(ttl = safeTTL, topic = sendTopic2,
                        payload = payload) == true
      node2.protocolState(Whisper).queue.items.len == 1

      await f.withTimeout(waitInterval)
      f.read() == 1
      node1.protocolState(Whisper).queue.items.len == 1

      node1.unsubscribeFilter(filter) == true

    await node1.setBloomFilter(fullBloom())

    resetMessageQueues(node1, node2)

  asyncTest "PoW blocking":
    let topic = [byte 0, 0, 0, 0]
    let payload = repeat(byte 0, 10)

    await node1.setPowRequirement(1_000_000)
    check:
      node2.postMessage(ttl = safeTTL, topic = topic, payload = payload) == true
      node2.protocolState(Whisper).queue.items.len == 1
    await sleepAsync(waitInterval)
    check:
      node1.protocolState(Whisper).queue.items.len == 0

    resetMessageQueues(node1, node2)

    await node1.setPowRequirement(0.0)
    check:
      node2.postMessage(ttl = safeTTL, topic = topic, payload = payload) == true
      node2.protocolState(Whisper).queue.items.len == 1
    await sleepAsync(waitInterval)
    check:
      node1.protocolState(Whisper).queue.items.len == 1

    resetMessageQueues(node1, node2)

  asyncTest "Queue pruning":
    let topic = [byte 0, 0, 0, 0]
    let payload = repeat(byte 0, 10)
    # We need a minimum TTL of 2 as when set to 1 there is a small chance that
    # it is already expired after messageInterval due to rounding down of float
    # to uint32 in postMessage()
    let lowerTTL = 2'u32 # Lower TTL as we need to wait for messages to expire
    for i in countdown(10, 1):
      check node2.postMessage(ttl = lowerTTL, topic = topic, payload = payload) == true
    check node2.protocolState(Whisper).queue.items.len == 10

    await sleepAsync(waitInterval)
    check node1.protocolState(Whisper).queue.items.len == 10

    await sleepAsync(milliseconds((lowerTTL+1)*1000))
    check node1.protocolState(Whisper).queue.items.len == 0
    check node2.protocolState(Whisper).queue.items.len == 0

    resetMessageQueues(node1, node2)

  asyncTest "P2P post":
    let topic = [byte 0, 0, 0, 0]
    var f: Future[int] = newFuture[int]()
    proc handler(msg: ReceivedMessage) =
      check msg.decoded.payload == repeat(byte 4, 10)
      f.complete(1)

    var filter = node1.subscribeFilter(initFilter(topics = @[topic],
                                       allowP2P = true), handler)
    check:
      node1.setPeerTrusted(toNodeId(node2.keys.pubkey)) == true
      node2.postMessage(ttl = 10, topic = topic,
                        payload = repeat(byte 4, 10),
                        targetPeer = some(toNodeId(node1.keys.pubkey))) == true

      await f.withTimeout(waitInterval)
      f.read() == 1
      node1.protocolState(Whisper).queue.items.len == 0
      node2.protocolState(Whisper).queue.items.len == 0

      node1.unsubscribeFilter(filter) == true

  asyncTest "Light node posting":
    var ln1 = setupTestNode(rng, Whisper)
    ln1.setLightNode(true)

    await ln1.peerPool.connectToNode(newNode(node2.toENode()))

    let topic = [byte 0, 0, 0, 0]

    check:
      # normal post
      ln1.postMessage(ttl = safeTTL, topic = topic,
                      payload = repeat(byte 0, 10)) == false
      ln1.protocolState(Whisper).queue.items.len == 0
      # P2P post
      ln1.postMessage(ttl = safeTTL, topic = topic,
                        payload = repeat(byte 0, 10),
                        targetPeer = some(toNodeId(node2.keys.pubkey))) == true
      ln1.protocolState(Whisper).queue.items.len == 0

  asyncTest "Connect two light nodes":
    var ln1 = setupTestNode(rng, Whisper)
    var ln2 = setupTestNode(rng, Whisper)

    ln1.setLightNode(true)
    ln2.setLightNode(true)

    ln2.startListening()
    let peer = await ln1.rlpxConnect(newNode(ln2.toENode()))
    check peer.isNil == true
