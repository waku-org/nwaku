import
  std/[options, sequtils, random],
  chronos, chronicles, stew/byteutils
  
import 
  waku/[waku_peer_exchange, node/peer_manager]

# import chronicles, chronos, stew/byteutils, results
# import waku/[common/logging, node/peer_manager, waku_core, waku_filter_v2/client]

proc main() {.async.} =
  let switch = newStandardSwitch()
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
  waitFor main()