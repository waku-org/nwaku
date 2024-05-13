when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

## Notice that the REST /lightpush requests normally assume that the node
## is acting as a lightpush-client that will trigger the service provider node
## to relay the message.
## In this module, we allow that a lightpush service node (full node) can be
## triggered directly through the  REST /lightpush endpoint.
## The typical use case for that is when using `nwaku-compose`,
## which spawn a full service Waku node
## that could be used also as a lightpush client, helping testing and development.

import stew/results, chronos, std/options, metrics
import
  ../waku_core,
  ./protocol,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../utils/requests

proc handleSelfLightPushRequest*(
    self: WakuLightPush, pubSubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async.} =
  ## Handles the lightpush requests made by the node to itself.
  ## Normally used in REST-lightpush requests

  try:
    # provide self peerId as now this node is used directly, thus there is no light client sender peer.
    let selfPeerId = self.peerManager.switch.peerInfo.peerId

    let req = PushRequest(pubSubTopic: pubSubTopic, message: message)
    let rpc = PushRPC(requestId: generateRequestId(self.rng), request: some(req))

    let respRpc = await self.handleRequest(selfPeerId, rpc.encode().buffer)

    if respRpc.response.isNone():
      waku_lightpush_errors.inc(labelValues = [emptyResponseBodyFailure])
      return err(emptyResponseBodyFailure)

    let response = respRpc.response.get()
    if not response.isSuccess:
      if response.info.isSome():
        return err(response.info.get())
      else:
        return err("unknown failure")

    return ok()
  except Exception:
    return err("exception in handleSelfLightPushRequest: " & getCurrentExceptionMsg())
