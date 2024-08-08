import random, chronos, chronicles, stew/byteutils, os
import waku/[waku_peer_exchange, node/peer_manager]
import tests/testlib/wakucore

proc connectToPeer(sw: Switch, peerAddr: string) {.async.} =
  let ma = MultiAddress.init(peerAddr).tryGet()
  let str = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let peerIdData = cast[seq[byte]](str)
  let peerId = PeerId(data: peerIdData)
  echo "2) ---------------> trying to connect with peer"
  await sw.connect(peerId, @[ma])
  # discard sw.dial(peerId, @[ma], "/vac/waku/peer-exchange/2.0.0-alpha1")
  echo "Connected to peer with address: ", peerAddr

proc main() {.async.} =
  echo "main started"
  let addrs =
    "/ip4/178.128.141.171/tcp/30303/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let switch = newStandardSwitch()
  discard switch.start()

  await connectToPeer(switch, addrs)
  if len(switch.connectedPeers(Direction.Out)) > 0:
    echo "Successfully out connected with Waku test fleet"
  elif len(switch.connectedPeers(Direction.In)) > 0:
    echo "Successfully in connected with Waku test fleet"
  else:
    echo "Not connected to any peers"

  let peerManager = PeerManager.new(switch)
  let wakuPx = WakuPeerExchange(peerManager: peerManager)

  for i in 1 .. 20:
    sleep(1000000)
    let response = await wakuPx.request(5)
    # check how many peerid arn't stale

when isMainModule:
  waitFor main()
