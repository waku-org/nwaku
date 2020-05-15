#
#                   Waku
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import unittest, options, tables, sets
import chronos, chronicles
import utils,
       libp2p/[errors,
               switch,
               connection,
               stream/bufferstream,
               crypto/crypto,
               protocols/pubsub/floodsub]
import ../../waku/protocol/v2/waku_protocol

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"

# TODO: Start with floodsub here, then move other logic here

# XXX: If I cast to WakuSub here I get a SIGSEGV
proc waitSub(sender, receiver: auto; key: string) {.async, gcsafe.} =
  # turn things deterministic
  # this is for testing purposes only
  var ceil = 15
  let fsub = cast[WakuSub](sender.pubSub.get())
  while not fsub.floodsub.hasKey(key) or
        not fsub.floodsub[key].contains(receiver.peerInfo.id):
    await sleepAsync(100.millis)
    dec ceil
    doAssert(ceil > 0, "waitSub timeout!")

suite "FloodSub":
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

  test "FloodSub basic publish/subscribe A -> B":
    proc runTests(): Future[bool] {.async.} =
      var completionFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        debug "Hit handler", topic
        check topic == "foobar"
        completionFut.complete(true)

      let
        nodes = generateNodes(2)
        nodesFut = await allFinished(
          nodes[0].start(),
          nodes[1].start()
        )

      await subscribeNodes(nodes)

      await nodes[1].subscribe("foobar", handler)
      await waitSub(nodes[0], nodes[1], "foobar")

      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))

      result = await completionFut.wait(5.seconds)

      await allFuturesThrowing(
        nodes[0].stop(),
        nodes[1].stop()
      )

      for fut in nodesFut:
        let res = fut.read()
        await allFuturesThrowing(res)
    check:
      waitFor(runTests()) == true
