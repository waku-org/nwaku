## Waku layer API — ping operation.
{.push raises: [].}

import
  chronos,
  chronicles,
  metrics,
  results,
  libp2p/protocols/ping,
  libp2p/builders,
  libp2p/transports/tcptransport

import
  logos_delivery/kernel/kernel, logos_delivery/kernel/node/peer_manager/peer_manager

logScope:
  topics = "waku node ping api"

import results, chronos, chronicles
import libp2p/protocols/ping
import libp2p/switch

import logos_delivery/kernel/[core/peers]

proc mountLibp2pPing*(node: Kernel) {.async: (raises: []).} =
  info "mounting libp2p ping protocol"

  try:
    node.protocols.libp2pPing = Ping.new(rng = node.rng)
  except Exception as e:
    error "failed to create ping", error = getCurrentExceptionMsg()

  if node.started:
    # Node has started already. Let's start ping too.
    try:
      await node.protocols.libp2pPing.start()
    except CatchableError:
      error "failed to start libp2pPing", error = getCurrentExceptionMsg()

  try:
    node.switch.mount(node.protocols.libp2pPing)
  except LPError:
    error "failed to mount libp2pPing", error = getCurrentExceptionMsg()

proc pingPeer*(
    self: Kernel, peerAddr: string, timeoutMs: int
): Future[Result[int64, string]] {.async.} =
  ## Pings the peer; `timeoutMs <= 0` means no timeout. Returns RTT in nanos.
  ## `peerAddr` is one fully qualified multiaddress, or several for the same
  ## peer separated by commas.
  try:
    let peerInfo = parsePeerAddrList(peerAddr).valueOr:
      return err("pingPeer failed to parse peer addr: " & $error)

    proc doPing(): Future[Result[Duration, string]] {.async.} =
      try:
        let conn = await self.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
        defer:
          await conn.close()
        let rtt = await self.protocols.libp2pPing.ping(conn)
        if rtt == 0.nanos:
          return err("could not ping peer: rtt-0")
        return ok(rtt)
      except CatchableError as e:
        return err("could not ping peer: " & e.msg)

    let pingFut = doPing()
    let rtt: Duration =
      if timeoutMs <= 0:
        (await pingFut).valueOr:
          return err(error)
      else:
        if not await pingFut.withTimeout(chronos.milliseconds(timeoutMs)):
          return err("ping timed out")
        pingFut.read().valueOr:
          return err(error)

    return ok(rtt.nanos)
  except CatchableError as e:
    return err(e.msg)
