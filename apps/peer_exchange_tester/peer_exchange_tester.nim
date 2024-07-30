# import random, strutils, asyncdispatch, chronos, chronicles, stew/byteutils, waku/[waku_peer_exchange, node/peer_manager], tests/testlib/wakucore
import random, chronos, chronicles, stew/byteutils
import waku/[waku_peer_exchange, node/peer_manager]
import tests/testlib/wakucore
import asyncdispatch as asyncd

proc createSwitch(): Switch =
  let addrs = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
  newStandardSwitch(addrs = addrs)

proc connectToPeer(sw: Switch, peerAddr: string) {.async.} =
  let ma = MultiAddress.init(peerAddr).tryGet()
  let str = "16Uiu2HAm2uZtDK3T4zgseP16uGB6s2q2i8zpviLBmXyukjU5BPVT"
  let peerIdData = str.mapIt(cast[byte](it))
  let peerId = PeerId(data: peerIdData)
  let connection = await sw.dial(peerId, @[ma], @["defaultProto"])

proc main() {.async.} =
  let addrs = "/ip4/139.99.173.27/tcp/30304"
  let switch = createSwitch()
  await switch.connectToPeer(addrs)
  let peerManager = PeerManager.new(switch)
  let wakuPx = WakuPeerExchange(peerManager: peerManager)

  # Request peers and check if they are live
  let res = await wakuPx.request(5)
  if res.isOk:
    let peers = res.get().peerInfos.mapIt(it.enr)
    for peer in peers:
      echo "Peer ENR: ", peer
      # Add your logic to dial and check if the peer is live
  else:
    echo "Error requesting peers: ", res.error

when isMainModule:
  asyncMain(main)
