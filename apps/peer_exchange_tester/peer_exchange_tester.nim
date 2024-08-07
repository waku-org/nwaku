# import random, strutils, asyncdispatch, chronos, chronicles, stew/byteutils, waku/[waku_peer_exchange, node/peer_manager], tests/testlib/wakucore
import random, chronicles, stew/byteutils
import waku/[waku_peer_exchange, node/peer_manager]
import tests/testlib/wakucore
import asyncdispatch

proc createSwitch(): Switch =
  let addrs = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
  return newStandardSwitch(addrs = addrs)

proc connectToPeer(sw: Switch, peerAddr: string) {.async.} =
  let ma = MultiAddress.init(peerAddr).tryGet()
  let str = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let peerIdData = cast[seq[byte]](str)
  let peerId = PeerId(data: peerIdData)
  await sw.connect(peerId, @[ma])
  echo "Connected to peer with address: ", peerAddr

proc main() {.async.} =
  let addrs = "/dns4/node-01.do-ams3.waku.test.status.im/tcp/30303/p2p"
  let switch = createSwitch()
  await connectToPeer(switch, addrs)
  let connectedPeers = switch.connectedPeers()
  if connectedPeers > 0:
    echo "Successfully connected with Waku test fleet"
  let peerManager = PeerManager.new(switch)
  let wakuPx = WakuPeerExchange(peerManager: peerManager)

when isMainModule:
  waitFor main()
