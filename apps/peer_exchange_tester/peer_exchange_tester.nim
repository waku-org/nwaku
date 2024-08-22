import chronos, chronicles, options, os
import libp2p/peerId
import eth/p2p/discoveryv5/enr
import
  waku/[
    waku_node,
    waku_peer_exchange,
    node/peer_manager,
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

  let switch = newStandardSwitch()
  discard switch.start()

  let addrs = "/ip4/178.128.141.171/tcp/30303/"
  let id = "16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W"
  let ma = MultiAddress.init(addrs).tryGet()
  let peerId = PeerId.init(id).tryGet()
  let peer_info = RemotePeerInfo.init(peerId, @[ma])

  var iter = 0
  var success = 0
  for i in 0 .. 60:
    echo "Seq No :- " & $i & " ---> "
    let response = await wakuApp.node.wakuPeerExchange.request(5, peer_info)
    if response.isOk:
      var validPeers = 0
      let peers = response.get().peerInfos
      for pi in peers:
        var record: enr.Record
        if enr.fromBytes(record, pi.enr):
          let peer_info = record.toRemotePeerInfo().get()
          let peerId = peer_info.peerId
          let ma = peer_info.addrs
          echo $iter & ") -----> " & $ma[0] & "  -- " & $peerId
          iter += 1
          try:
            let wait = 20000
            let conn = await switch
            .dial(peerId, ma, "/vac/waku/metadata/1.0.0")
            .withTimeout(wait)
          except TimeoutError:
            echo "Dialing peer " & $peerId & " timed out."
          except:
            echo "An error occurred while dialing peer " & $peerId

          success += len(switch.connectedPeers(Direction.Out))
          echo $success & " out of " & $iter & " operation successful"
          discard switch.disconnect(peerId)
    else:
      echo " ------------ response isn't not ok ------------------"
    sleep(120000)
    while iter mod 5 == 0:
      iter += 1
  echo "---------------------------- Done ------------------------------- "

when isMainModule:
  waitFor main()
