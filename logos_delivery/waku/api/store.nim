## Waku layer API — store (historical query) operations.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/kernel
import
  logos_delivery/waku/
    [waku_core, node/waku_node, node/peer_manager, waku_store/common, waku_store/client]

proc isStoreMounted*(self: Kernel): bool =
  ## True if a store client is mounted (the node can run store queries).
  return not self.protocols.storeClient.isNil()

proc hasStorePeer*(self: Kernel): bool =
  ## True if at least one store service peer is available to query.
  return self.peerManager.selectPeer(WakuStoreCodec).isSome()

proc storeQueryToAny*(
    self: Kernel, request: StoreQueryRequest
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against any available store peer (retries across peers).
  try:
    if self.protocols.storeClient.isNil():
      return err("wakuStoreClient is not mounted")

    let queryResponse = (await self.protocols.storeClient.queryToAny(request)).valueOr:
      return err($error)

    return ok(queryResponse)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err(e.msg)

proc storeQuery*(
    self: Kernel, request: StoreQueryRequest, peer: string, timeoutMs: int
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against one store peer. `peer` is one fully qualified
  ## multiaddress, or several for the same peer separated by commas.
  try:
    if self.protocols.storeClient.isNil():
      return err("wakuStoreClient is not mounted")

    let remotePeer = parsePeerAddrList(peer).valueOr:
      return err("storeQuery failed to parse peer addr: " & $error)

    let queryFut = self.protocols.storeClient.query(request, remotePeer)
    if not await queryFut.withTimeout(timeoutMs.milliseconds):
      return err("storeQuery timed out")

    let queryResponse = queryFut.read().valueOr:
      return err("storeQuery failed: " & $error)

    return ok(queryResponse)
  except CatchableError as e:
    return err(e.msg)
