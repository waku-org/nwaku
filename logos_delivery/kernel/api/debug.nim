## Waku layer API — debug / info operations.
{.push raises: [].}

import results, chronos, metrics
import eth/p2p/discoveryv5/enr
import libp2p/peerid # pull PeerId pretty string formatting

import logos_delivery/kernel/kernel
proc version*(self: Kernel): Future[Result[string, string]] {.async.} =
  return ok(WakuNodeVersionString)

proc listenAddresses*(self: Kernel): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(self.info().listenAddresses)
  except CatchableError as e:
    return err(e.msg)

proc myEnr*(self: Kernel): Future[Result[string, string]] {.async.} =
  try:
    return ok(self.enr.toURI())
  except CatchableError as e:
    return err(e.msg)

proc myPeerId*(self: Kernel): Future[Result[string, string]] {.async.} =
  try:
    return ok($self.peerId())
  except CatchableError as e:
    return err(e.msg)

proc metrics*(self: Kernel): Future[Result[string, string]] {.async.} =
  {.gcsafe.}:
    try:
      return ok(defaultRegistry.toText())
    except CatchableError as e:
      return err(e.msg)
