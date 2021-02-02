#
#                   Waku
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)
{.used.}

import unittest, options, tables, sets, sequtils
import chronos, chronicles
import utils,
       libp2p/errors,
       libp2p/switch,
       libp2p/protobuf/minprotobuf,
       libp2p/stream/[bufferstream, connection],
       libp2p/crypto/crypto,
       libp2p/protocols/pubsub/floodsub
import ../../waku/v2/protocol/waku_relay

import ../test_helpers

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"

# TODO: Start with floodsub here, then move other logic here

# XXX: If I cast to WakuRelay here I get a SIGSEGV
proc waitSub(sender, receiver: auto; key: string) {.async, gcsafe.} =
  # turn things deterministic
  # this is for testing purposes only
  var ceil = 15
  let fsub = cast[WakuRelay](sender.pubSub.get())
  while not fsub.floodsub.hasKey(key) or
        not fsub.floodsub[key].anyIt(it.peerInfo.id == receiver.peerInfo.id):
    await sleepAsync(100.millis)
    dec ceil
    doAssert(ceil > 0, "waitSub timeout!")

proc message(): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, "hello")
  pb.finish()

  pb.buffer

proc decodeMessage(data: seq[byte]): string =
  var pb = initProtoBuffer(data)
  
  result = ""
  let res = pb.getField(1, result)

procSuite "FloodSub":
  teardown:
    let
      trackers = [
        # getTracker(ConnectionTrackerName),
        getTracker(BufferStreamTrackerName),
        getTracker(AsyncStreamWriterTrackerName),
        getTracker(AsyncStreamReaderTrackerName),
        getTracker(StreamTransportTrackerName),
        getTracker(StreamServerTrackerName)
      ]
    for tracker in trackers:
      if not isNil(tracker):
        check tracker.isLeaked() == false

  asyncTest "FloodSub basic publish/subscribe A -> B":
    var completionFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      debug "Hit handler", topic
      let msg = decodeMessage(data)
      check topic == "foobar"
      check msg == "hello"
      completionFut.complete(true)

    let
      nodes = generateNodes(2)
      
      nodesFut = await allFinished(
        nodes[0].start(),
        nodes[1].start()
      )

    for node in nodes:
      node.mountRelay()

    await subscribeNodes(nodes)

    await nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    # TODO: you might want to check the value here
    let msg = message()
    discard await nodes[0].publish("foobar", msg)

    check: await completionFut.wait(5.seconds)

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
    )

    for fut in nodesFut:
      let res = fut.read()
      await allFuturesThrowing(res)
