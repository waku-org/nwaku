## Waku on libp2p
##
## This file should eventually correspond to waku_protocol as RLPx subprotocol.
## Instead, it should likely be on top of GossipSub with a similar interface.

import unittest
import sequtils, tables, options, sets, strutils
import chronos, chronicles
import ../../vendor/nim-libp2p/libp2p/protocols/pubsub/pubsub,
       ../../vendor/nim-libp2p/libp2p/protocols/pubsub/pubsubpeer,
       ../../vendor/nim-libp2p/libp2p/protocols/pubsub/floodsub
import ../../vendor/nim-libp2p/tests/pubsub/utils

# XXX: Hacky in-line test for now

logScope:
    topic = "WakuSub"

# For spike
const WakuSubCodec* = "/WakuSub/0.0.1"

#const wakuVersionStr = "2.0.0-alpha1"

# So this should already have floodsub table, seen, as well as peerinfo, topics, peers, etc
# How do we verify that in nim?
type
  WakuSub* = ref object of FloodSub
    # XXX: just playing
    text*: string

# method subscribeTopic
# method handleDisconnect
# method rpcHandler
# method init
# method publish
# method unsubscribe
# method initPubSub

# To defer to parent object something like:
# procCall PubSub(f).publish(topic, data)

# Then we should be able to write tests like floodsub test

# Can also do in-line here


# XXX: Testing in-line
proc waitSub(sender, receiver: auto; key: string) {.async, gcsafe.} =
  # turn things deterministic
  # this is for testing purposes only
  var ceil = 15
  # TODO: Cast WakuSub
  let fsub = cast[FloodSub](sender.pubSub.get())
  while not fsub.floodsub.hasKey(key) or
        not fsub.floodsub[key].contains(receiver.peerInfo.id):
    await sleepAsync(100.millis)
    dec ceil
    doAssert(ceil > 0, "waitSub timeout!")

proc test(): Future[bool] {.async.} =
  var completionFut = newFuture[bool]()
  proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    echo "HIT HANDLER", topic
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

  echo "ok"
  result = await completionFut.wait(5.seconds)

#  await allFuturesThrowing(
#    nodes[0].stop(),
#    nodes[1].stop()
#  )
#
#  for fut in nodesFut:
#    let res = fut.read()
#    await allFuturesThrowing(res)

echo "Starting"
var res = waitFor test()
echo "Done with res: ", $res
