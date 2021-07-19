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
  chronos, testutils/unittests, eth/p2p, eth/p2p/peer_pool,
  ../../waku/whisper/whisper_protocol as whisper,
  ../../waku/v1/protocol/waku_protocol as waku,
  ../../waku/v1/protocol/waku_bridge,
  ../test_helpers

let safeTTL = 5'u32
let waitInterval = waku.messageInterval + 150.milliseconds

procSuite "Waku - Whisper bridge tests":
  let rng = newRng()
  # Waku Whisper node has both capabilities, listens to Whisper and Waku and
  # relays traffic between the two.
  var
    nodeWakuWhisper = setupTestNode(rng, Whisper, Waku) # This will be the bridge
    nodeWhisper = setupTestNode(rng, Whisper)
    nodeWaku = setupTestNode(rng, Waku)

  nodeWakuWhisper.startListening()
  let bridgeNode = newNode(nodeWakuWhisper.toENode())
  nodeWakuWhisper.shareMessageQueue()

  waitFor nodeWhisper.peerPool.connectToNode(bridgeNode)
  waitFor nodeWaku.peerPool.connectToNode(bridgeNode)

  asyncTest "WakuWhisper and Whisper peers connected":
    check:
      nodeWhisper.peerPool.connectedNodes.len() == 1
      nodeWaku.peerPool.connectedNodes.len() == 1

  asyncTest "Whisper - Waku communcation via bridge":
    # topic whisper node subscribes to, waku node posts to
    let topic1 = [byte 0x12, 0, 0, 0]
    # topic waku node subscribes to, whisper node posts to
    let topic2 = [byte 0x34, 0, 0, 0]
    var payloads = [repeat(byte 0, 10), repeat(byte 1, 10)]
    var futures = [newFuture[int](), newFuture[int]()]

    proc handler1(msg: whisper.ReceivedMessage) =
      check msg.decoded.payload == payloads[0]
      futures[0].complete(1)
    proc handler2(msg: waku.ReceivedMessage) =
      check msg.decoded.payload == payloads[1]
      futures[1].complete(1)

    var filter1 = whisper.subscribeFilter(nodeWhisper,
      whisper.initFilter(topics = @[topic1]), handler1)
    var filter2 = waku.subscribeFilter(nodeWaku,
      waku.initFilter(topics = @[topic2]), handler2)

    check:
      # Message should also end up in the Whisper node its queue via the bridge
      waku.postMessage(nodeWaku, ttl = safeTTL + 1, topic = topic1,
                              payload = payloads[0]) == true
      # Message should also end up in the Waku node its queue via the bridge
      whisper.postMessage(nodeWhisper, ttl = safeTTL, topic = topic2,
                              payload = payloads[1]) == true
      nodeWhisper.protocolState(Whisper).queue.items.len == 1
      nodeWaku.protocolState(Waku).queue.items.len == 1

      # waitInterval*2 as messages have to pass the bridge also (2 hops)
      await allFutures(futures).withTimeout(waitInterval*2)

      # Relay can receive Whisper & Waku messages
      nodeWakuWhisper.protocolState(Whisper).queue.items.len == 2
      nodeWakuWhisper.protocolState(Waku).queue.items.len == 2

      # Whisper node can receive Waku messages (via bridge)
      nodeWhisper.protocolState(Whisper).queue.items.len == 2
      # Waku node can receive Whisper messages (via bridge)
      nodeWaku.protocolState(Waku).queue.items.len == 2

      whisper.unsubscribeFilter(nodeWhisper, filter1) == true
      waku.unsubscribeFilter(nodeWaku, filter2) == true

    # XXX: This reads a bit weird, but eh
    waku.resetMessageQueue(nodeWaku)
    whisper.resetMessageQueue(nodeWhisper)
    # shared queue so Waku and Whisper should be set to 0
    waku.resetMessageQueue(nodeWakuWhisper)

    check:
      nodeWhisper.protocolState(Whisper).queue.items.len == 0
      nodeWaku.protocolState(Waku).queue.items.len == 0
      nodeWakuWhisper.protocolState(Whisper).queue.items.len == 0
      nodeWakuWhisper.protocolState(Waku).queue.items.len == 0
