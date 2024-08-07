# import random, strutils, asyncdispatch, chronos, chronicles, stew/byteutils, waku/[waku_peer_exchange, node/peer_manager], tests/testlib/wakucore
import random, chronicles, stew/byteutils
import waku/[waku_peer_exchange, node/peer_manager]
import tests/testlib/wakucore
import asyncdispatch

proc createSwitch(): Switch =
  let addrs = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
  newStandardSwitch(addrs = addrs)

proc connectToPeer(sw: Switch, peerAddr: string) {.async.} =
  let ma = MultiAddress.init(peerAddr).tryGet()
  let str = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let peerIdData = cast[seq[byte]](str)
  let peerId = PeerId(data: peerIdData)
  # sw.dial(peerId, @[ma], @["/vac/waku/peer-exchange/2.0.0-alpha1"])

proc main() {.async.} =
  let addrs = "/dns4/node-01.do-ams3.waku.test.status.im/tcp/30303/p2p"
  let switch = createSwitch()
  await switch.connectToPeer(addrs)
  let peerManager = PeerManager.new(switch)
  let wakuPx = WakuPeerExchange(peerManager: peerManager)

when isMainModule:
  asyncMain(main)
