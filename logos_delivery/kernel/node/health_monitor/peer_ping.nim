{.push raises: [].}

import std/random, chronos, chronicles, results, libp2p/peerid, libp2p/protocols/ping
import logos_delivery/kernel/node/peer_manager/peer_manager

logScope:
  topics = "waku node ping api"

proc selectRandomPeers*(peers: seq[PeerId], numRandomPeers: int): seq[PeerId] =
  var randomPeers = peers
  shuffle(randomPeers)
  return randomPeers[0 ..< min(len(randomPeers), numRandomPeers)]

proc pingPeer(
    peerManager: PeerManager, ping: Ping, peerId: PeerId
): Future[Result[void, string]] {.async.} =
  ## Ping a single peer and return the result

  try:
    # Establish a stream
    let stream = (await peerManager.dialPeer(peerId, PingCodec)).valueOr:
      debug "pingPeer: failed dialing peer", peerId = peerId
      return err("pingPeer failed dialing peer peerId: " & $peerId)
    defer:
      # Always close the stream
      # Workaround for Nim 2.2.6 mishandling `try: await` inside defer (Nim issue 25330)
      # TODO: revert to a plain await on Nim >= 2.2.8
      let closeFut =
        try:
          stream.close()
        except CatchableError as e:
          debug "Error closing ping connection", peerId = peerId, error = e.msg
          nil
      if not closeFut.isNil():
        try:
          await closeFut
        except CatchableError as e:
          debug "Error closing ping connection", peerId = peerId, error = e.msg

    # Perform ping
    let pingDuration = await ping.ping(stream)

    trace "Ping successful", peerId = peerId, duration = pingDuration
    return ok()
  except CatchableError as e:
    debug "pingPeer: exception raised pinging peer", peerId = peerId, error = e.msg
    return err("pingPeer: exception raised pinging peer: " & e.msg)

# Returns the number of succesful pings performed
proc parallelPings*(
    peerManager: PeerManager, ping: Ping, peerIds: seq[PeerId]
): Future[int] {.async.} =
  if len(peerIds) == 0:
    return 0

  var pingFuts: seq[Future[Result[void, string]]]

  # Create ping futures for each peer
  for i, peerId in peerIds:
    let fut = pingPeer(peerManager, ping, peerId)
    pingFuts.add(fut)

  # Wait for all pings to complete
  discard await allFutures(pingFuts).withTimeout(5.seconds)

  var successCount = 0
  for fut in pingFuts:
    if not fut.completed() or fut.failed():
      continue

    let res = fut.read()
    if res.isOk():
      successCount.inc()

  return successCount
