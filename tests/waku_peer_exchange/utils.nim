{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  ../../../waku/[
    waku_node,
    waku_discv5,
    waku_peer_exchange,
    waku_peer_exchange/rpc,
    waku_peer_exchange/protocol,
    node/peer_manager,
    waku_core
  ],
  ../testlib/[futures, wakucore]

proc dialForPeerExchange*(
    client: WakuNode,
    peerInfo: RemotePeerInfo,
    requestedPeers: uint64 = 1,
    minimumPeers: uint64 = 0,
    attempts: uint64 = 10,
): Future[Result[uint64, string]] {.async.} =
  # Dials a peer and awaits until it's able to receive a peer exchange response
  # For the test, the relevant part is the dialPeer call. 
  # But because the test needs peers, and due to the asynchronous nature of the dialing,
  # we await until we receive peers from the peer exchange protocol.
  var attempts = attempts

  while attempts > 0:
    let connOpt = await client.peerManager.dialPeer(peerInfo, WakuPeerExchangeCodec)
    require connOpt.isSome
    await sleepAsync(FUTURE_TIMEOUT)

    let response = await client.wakuPeerExchange.request(requestedPeers, connOpt.get())
    require response.isOk

    let peerInfosLen = uint64(response.get().peerInfos.len)
    if peerInfosLen > minimumPeers:
      return ok(peerInfosLen)

    attempts -= 1

  return err("Attempts exhausted.")
