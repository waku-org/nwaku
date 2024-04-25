##
## This file is aimed to attend the requests that come directly
## from the 'self' node. It is expected to attend the store requests that
## come from REST-store endpoint when those requests don't indicate
## any store-peer address.
##
## Notice that the REST-store requests normally assume that the REST
## server is acting as a store-client. In this module, we allow that
## such REST-store node can act as store-server as well by retrieving
## its own stored messages. The typical use case for that is when
## using `nwaku-compose`, which spawn a Waku node connected to a local
## database, and the user is interested in retrieving the messages
## stored by that local store node.
##

import stew/results, chronos, chronicles, std/options, metrics
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
