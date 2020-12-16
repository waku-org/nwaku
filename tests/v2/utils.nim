# compile time options here
const
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true

import random
import chronos
import libp2p/[standard_setup,
               protocols/pubsub/pubsub,
               protocols/secure/secure]
import ../../waku/v2/waku_types

export standard_setup

randomize()

proc generateNodes*(
  num: Natural,
  secureManagers: openarray[SecureProtocol] = [
    # array cos order matters
    SecureProtocol.Secio,
    SecureProtocol.Noise,
  ],
  msgIdProvider: MsgIdProvider = nil,
  gossip: bool = false,
  triggerSelf: bool = false,
  verifySignature: bool = libp2p_pubsub_verify,
  sign: bool = libp2p_pubsub_sign): seq[PubSub] =

  for i in 0..<num:
    let switch = newStandardSwitch(secureManagers = secureManagers)
    let wakuRelay = WakuRelay.init(
      switch = switch,
      triggerSelf = triggerSelf,
      verifySignature = verifySignature,
      sign = sign,
      # XXX unclear why including this causes a compiler error, it is part of WakuRelay type
      msgIdProvider = msgIdProvider).PubSub

    switch.mount(wakuRelay)
    result.add(wakuRelay)

proc subscribeNodes*(nodes: seq[PubSub]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.switch.peerInfo.peerId != node.switch.peerInfo.peerId:
        await dialer.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
        dialer.subscribePeer(node.peerInfo.peerId)

proc subscribeSparseNodes*(nodes: seq[PubSub], degree: int = 2) {.async.} =
  if nodes.len < degree:
    raise (ref CatchableError)(msg: "nodes count needs to be greater or equal to degree!")

  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue

    for node in nodes:
      if dialer.switch.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
        dialer.subscribePeer(node.peerInfo.peerId)

proc subscribeRandom*(nodes: seq[PubSub]) {.async.} =
  for dialer in nodes:
    var dialed: seq[PeerID]
    while dialed.len < nodes.len - 1:
      let node = sample(nodes)
      if node.peerInfo.peerId notin dialed:
        if dialer.peerInfo.peerId != node.peerInfo.peerId:
          await dialer.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
          dialer.subscribePeer(node.peerInfo.peerId)
          dialed.add(node.peerInfo.peerId)
