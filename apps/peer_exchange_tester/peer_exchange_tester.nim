import random, chronos, chronicles, stew/byteutils, os
import libp2p/peerId
import waku/[waku_peer_exchange, node/peer_manager]
import tests/testlib/wakucore

proc connectToPeer(sw: Switch, peerAddr: string) {.async.} =
  let ma = MultiAddress.init(peerAddr).tryGet()
  let str = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  # let peerIdData = cast[seq[byte]](str)
  let peerId = PeerId.init(str).tryGet()
  await sw.connect(peerId, @[ma])
  discard sw.dial(peerId, @[ma], "/vac/waku/peer-exchange/2.0.0-alpha1")
  echo "Connected to peer with address: ", peerAddr

proc main() {.async.} =
  echo "main started"
  let addrs = "/ip4/178.128.141.171/tcp/30303/"
  let switch = newStandardSwitch()
  discard switch.start()
  echo "\n ---------------------------------- switch started ----------------------------------------- \n"
  await connectToPeer(switch, addrs)
  if len(switch.connectedPeers(Direction.Out)) > 0:
    echo "Successfully out connected with Waku test fleet"
  elif len(switch.connectedPeers(Direction.In)) > 0:
    echo "Successfully in connected with Waku test fleet"
  else:
    echo "Not connected to any peers"
  
  echo "\n ---------------------------------- connection completed -------------------------------- \n"

  let peerManager = PeerManager.new(switch)
  let wakuPx = WakuPeerExchange(peerManager: peerManager)
  
  echo "----------------------------------------------------------------------------------------------"
  for i in 1 .. 20:
    echo "Seq No :- " & $i & " ---> "
    echo $wakuPx.enrCache 
    sleep(120000)
  # let res1 = await wakuPx.request(1)
  # echo "\n -------------------------------- response -------------------------------------\n"
  # if res1.isOk:
      # echo "response count :- " & $res1.get().peerInfos.len
  # echo "\n -------------- requested 4 peer through px protocol ------------------------------------\n"
  # echo res1
  # for i in 1 .. 20: 
  #   echo "Request no :- " & $i & " ------> "
  #   let res1 = await wakuPx.request(5)
  #   if res1.get().peerInfos.len == 5:
  #     echo "It's 5 peers"
  #   else:
  #     echo "it isn't 5 peers" 
  #   sleep(300000)
  echo "---------------------------- Done ------------------------------- " 
when isMainModule:
  waitFor main()
