# import random, strutils, asyncdispatch, chronos, chronicles, stew/byteutils, waku/[waku_peer_exchange, node/peer_manager], tests/testlib/wakucore
import random, chronos, chronicles, stew/byteutils, os
import waku/[waku_peer_exchange, node/peer_manager]
import tests/testlib/wakucore

proc createSwitch(): Switch =
  echo "switch created"
  let addrs = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
  return newStandardSwitch(addrs = addrs)

proc connectToPeer(sw: Switch, peerAddr: string) {.async.} =
  let ma = MultiAddress.init(peerAddr).tryGet()
  let str = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let peerIdData = cast[seq[byte]](str)
  let peerId = PeerId(data: peerIdData)
  echo "trying to connect with peer"
  # await sw.connect(peerId, @[ma])
  # discard sw.dial(peerId, "/vac/waku/peer-exchange/2.0.0-alpha1")
  echo "Connected to peer with address: ", peerAddr

proc main() {.async.} =
  echo "main started"
  let addrs = "/ip4/178.128.141.171/tcp/30303"
  let switch = createSwitch()
  await connectToPeer(switch, addrs)
  if len(switch.connectedPeers(Direction.Out)) > 0:
    sleep(10000)
    echo "Successfully out connected with Waku test fleet"
  elif len(switch.connectedPeers(Direction.In)) > 0:
    sleep(10000)
    echo "Successfully in connected with Waku test fleet"
  else:
    sleep(10000)
    echo "Not connected to any peers"
  let peerManager = PeerManager.new(switch)
  let wakuPx = WakuPeerExchange(peerManager: peerManager)

when isMainModule:
  waitFor main()