import std/[json, strutils]
import chronos, results, ffi
import libp2p/[protocols/ping, switch, multiaddress, multicodec]
import ../../waku/[factory/waku, waku_core/peers, node/waku_node]

registerReqFFI(PingReq, waku: ptr Waku):
  proc(peerAddr: cstring, timeoutMs: cuint): Future[Result[string, string]] {.async.} =
    let peerInfo = peers.parsePeerInfo(($peerAddr).split(",")).valueOr:
      return err("PingRequest failed to parse peer addr: " & $error)

    let timeout = chronos.milliseconds(timeoutMs)
    proc ping(): Future[Result[Duration, string]] {.async, gcsafe.} =
      try:
        let conn =
          await waku.node.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
        defer:
          await conn.close()

        let pingRTT = await waku.node.libp2pPing.ping(conn)
        if pingRTT == 0.nanos:
          return err("could not ping peer: rtt-0")
        return ok(pingRTT)
      except CatchableError as exc:
        return err("could not ping peer: " & exc.msg)

    let pingFuture = ping()
    let pingRTT: Duration =
      if timeout == chronos.milliseconds(0): # No timeout expected
        (await pingFuture).valueOr:
          return err("ping failed, no timeout expected: " & error)
      else:
        let timedOut = not (await pingFuture.withTimeout(timeout))
        if timedOut:
          return err("ping timed out")
        pingFuture.read().valueOr:
          return err("failed to read ping future: " & error)

    return ok($(pingRTT.nanos))
