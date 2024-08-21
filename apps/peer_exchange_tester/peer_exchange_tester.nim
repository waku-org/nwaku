import random, chronos, chronicles, stew/byteutils, os, osproc, strutils
import strutils, options, nimcrypto
import options, nimcrypto
import libp2p/peerId
import
  waku/[
    waku_node,
    waku_peer_exchange,
    node/peer_manager,
    node/peer_manager/peer_store/waku_peer_storage,
    node/peer_manager/peer_manager,
    node/peer_manager,
    factory/waku,
    factory/external_config,
    common/logging,
  ]

proc main() {.async.} =
  echo "--------------- main started ---------------"

  var wakuConf: WakuNodeConf
  wakuConf.logLevel = logging.LogLevel.DEBUG
  wakuConf.logFormat = logging.LogFormat.TEXT
  wakuConf.staticNodes =
    @[
      "/ip4/178.128.141.171/tcp/30303/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
    ]
  wakuConf.maxConnections = 100
  wakuConf.pubsubTopics = @["/waku/2/rs/0/0"]
  wakuConf.clusterId = 1
  wakuConf.nat = "extip:117.99.49.10"
  wakuConf.relayPeerExchange = true
  wakuConf.peerExchange = true

  var wakuApp = Waku.init(wakuConf).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  (waitFor startWaku(addr wakuApp)).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  echo "--------------------------------------------------------------------------------"

  let addrs = "/ip4/178.128.141.171/tcp/30303/"
  let id = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let ma = MultiAddress.init(addrs).tryGet()
  let peerId = PeerId.init(id).tryGet()
  let peer_info = RemotePeerInfo.init(peerId, @[ma])

  let response = await wakuApp.node.wakuPeerExchange.request(2, peer_info)

  # echo $response
  echo $response.get().peerInfos

  let pxInfo = response.get().peerInfos

  for info in pxInfo:
    # echo info.enr.Record()
    let info_str = cast[string](info.enr)

    echo info_str
    echo "------------------"
    echo info
    echo "------------------"
    # enr = info_str
    # let ip = enr["ip4"] 
    # let port = enr["tcp"]

    # let pubkey = enr["secp256k1"]
    # let peerId = PeerId.initFromPubKey(pubkey).get()

    # let addrs = fmt"/ip4/{ip}/tcp/{port}"
    # let ma = MultiAddress.init(addrs).tryGet()

    # let peerInfo = RemotePeerInfo.init(peerId, @[ma])

    # echo peerInfo

  if response.isOk:
    echo "--------------------------- peer exchange succesfully -------------------------"

  # let wakuPx = WakuPeerExchange(peerManager: peerManager)

  # for i in 1 .. 20:
  #   echo "Seq No :- " & $i & " ---> "
  #   echo $wakuPx.enrCache

  #   let res1 = await wakuPx.request(1)
  #   if res1.isOk:
  #     echo "response count :- " & $res1.get().peerInfos.len
  #   else:
  #       echo "request isn't ok"

  #   sleep(120000)

  echo "---------------------------- Done ------------------------------- "

when isMainModule:
  waitFor main()
