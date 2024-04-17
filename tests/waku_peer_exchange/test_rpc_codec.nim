{.used.}

import
  std/[options],
  testutils/unittests,
  chronos,
  stew/shims/net,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  ../../../waku/[
    node/peer_manager,
    discovery/waku_discv5,
    waku_peer_exchange/rpc,
    waku_peer_exchange/rpc_codec,
  ],
  ../testlib/[wakucore]

suite "Peer Exchange RPC":
  asyncTest "Encode - Decode":
    # Setup
    var
      enr1 = enr.Record(seqNum: 0, raw: @[])
      enr2 = enr.Record(seqNum: 0, raw: @[])

    check:
      enr1.fromUri(
        "enr:-JK4QPmO-sE2ELiWr8qVFs1kaY4jQZQpNaHvSPRmKiKcaDoqYRdki2c1BKSliImsxFeOD_UHnkddNL2l0XT9wlsP0WEBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQIMwKqlOl3zpwnrsKRKHuWPSuFzit1Cl6IZvL2uzBRe8oN0Y3CC6mKDdWRwgiMqhXdha3UyDw"
      )
      enr2.fromUri(
        "enr:-Iu4QK_T7kzAmewG92u1pr7o6St3sBqXaiIaWIsFNW53_maJEaOtGLSN2FUbm6LmVxSfb1WfC7Eyk-nFYI7Gs3SlchwBgmlkgnY0gmlwhI5d6VKJc2VjcDI1NmsxoQLPYQDvrrFdCrhqw3JuFaGD71I8PtPfk6e7TJ3pg_vFQYN0Y3CC6mKDdWRwgiMq"
      )

    let
      peerInfos =
        @[PeerExchangePeerInfo(enr: enr1.raw), PeerExchangePeerInfo(enr: enr2.raw)]
      rpc = PeerExchangeRpc(response: PeerExchangeResponse(peerInfos: peerInfos))

    # When encoding and decoding
    let
      rpcBuffer: seq[byte] = rpc.encode().buffer
      res = PeerExchangeRpc.decode(rpcBuffer)

    # Then the peerInfos match the originals
    check:
      res.isOk
      res.get().response.peerInfos == peerInfos

    # When using the decoded responses to create new enrs
    var
      resEnr1 = enr.Record(seqNum: 0, raw: @[])
      resEnr2 = enr.Record(seqNum: 0, raw: @[])

    discard resEnr1.fromBytes(res.get().response.peerInfos[0].enr)
    discard resEnr2.fromBytes(res.get().response.peerInfos[1].enr)

    # Then they match the original enrs
    check:
      resEnr1 == enr1
      resEnr2 == enr2
