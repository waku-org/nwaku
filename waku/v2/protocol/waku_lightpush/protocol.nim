{.push raises: [Defect].}

import
  std/options,
  stew/results,
  chronicles,
  chronos,
  metrics,
  bearssl,
  libp2p/crypto/crypto

import
  ../waku_message,
  ../waku_relay,
  ../../node/peer_manager/peer_manager,
  ../../utils/requests,
  ./rpc,
  ./rpc_codec


logScope:
  topics = "wakulightpush"

declarePublicGauge waku_lightpush_peers, "number of lightpush peers"
declarePublicGauge waku_lightpush_errors, "number of lightpush protocol errors", ["type"]
declarePublicGauge waku_lightpush_messages, "number of lightpush messages received", ["type"]


const
  WakuLightPushCodec* = "/vac/waku/lightpush/2.0.0-beta1"

const
  MaxRpcSize* = MaxWakuMessageSize + 64 * 1024 # We add a 64kB safety buffer for protocol overhead

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"


type
  PushResponseHandler* = proc(response: PushResponse) {.gcsafe, closure.}

  PushRequestHandler* = proc(requestId: string, msg: PushRequest) {.gcsafe, closure.}

  WakuLightPushResult*[T] = Result[T, string]

  WakuLightPush* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    peerManager*: PeerManager
    requestHandler*: PushRequestHandler
    relayReference*: WakuRelay


proc init*(wl: WakuLightPush) =

  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let message = await conn.readLp(MaxRpcSize.int)
    let res = PushRPC.init(message)
    if res.isErr():
      error "failed to decode rpc"
      waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
      return

    let rpc = res.get()

    if rpc.request != PushRequest():
      info "lightpush push request"
      waku_lightpush_messages.inc(labelValues = ["PushRequest"])

      let
        pubSubTopic = rpc.request.pubSubTopic
        message = rpc.request.message
      debug "PushRequest", pubSubTopic=pubSubTopic, msg=message

      var response: PushResponse
      if not wl.relayReference.isNil():
        let data = message.encode().buffer

        # Assumimng success, should probably be extended to check for network, peers, etc
        discard wl.relayReference.publish(pubSubTopic, data)
        response = PushResponse(is_success: true, info: "Totally.")
      else:
        debug "No relay protocol present, unsuccesssful push"
        response = PushResponse(is_success: false, info: "No relay protocol")
        
      
      let rpc = PushRPC(requestId: rpc.requestId, response: response)
      await conn.writeLp(rpc.encode().buffer)

    if rpc.response != PushResponse():
      waku_lightpush_messages.inc(labelValues = ["PushResponse"])
      if rpc.response.isSuccess:
        info "lightpush message success"
      else:
        info "lightpush message failure", info=rpc.response.info

  wl.handler = handle
  wl.codec = WakuLightPushCodec

proc init*(T: type WakuLightPush, peerManager: PeerManager, rng: ref BrHmacDrbgContext, handler: PushRequestHandler, relay: WakuRelay = nil): T =
  debug "init"
  let rng = crypto.newRng()
  let wl = WakuLightPush(rng: rng,
                         peerManager: peerManager, 
                         requestHandler: handler, 
                         relayReference: relay)
  wl.init()
  
  return wl


proc setPeer*(wlp: WakuLightPush, peer: RemotePeerInfo) =
  wlp.peerManager.addPeer(peer, WakuLightPushCodec)
  waku_lightpush_peers.inc()


proc request(wl: WakuLightPush, req: PushRequest, peer: RemotePeerInfo): Future[WakuLightPushResult[PushResponse]] {.async, gcsafe.} = 
  let connOpt = await wl.peerManager.dialPeer(peer, WakuLightPushCodec)
  if connOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)

  let connection = connOpt.get()

  let rpc = PushRPC(requestId: generateRequestId(wl.rng), request: req)
  await connection.writeLP(rpc.encode().buffer)

  var message = await connection.readLp(MaxRpcSize.int)
  let res = PushRPC.init(message)

  if res.isErr():
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return err(decodeRpcFailure)

  let rpcRes = res.get()
  if rpcRes.response == PushResponse():
    return err("empty response body")

  return ok(rpcRes.response)

proc request*(wl: WakuLightPush, req: PushRequest): Future[WakuLightPushResult[PushResponse]] {.async, gcsafe.} =
  let peerOpt = wl.peerManager.selectPeer(WakuLightPushCodec)
  if peerOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)

  return await wl.request(req, peerOpt.get())

proc request*(wl: WakuLightPush, req: PushRequest, handler: PushResponseHandler) {.async, gcsafe,
  deprecated: "Use the no-callback request() procedure".} =
  let res = await wl.request(req)
  if res.isErr():
    return
  
  handler(res.get())