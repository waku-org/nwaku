import
  std/[tables],
  bearssl,
  libp2p/protocols/protocol,
  ../../node/peer_manager/peer_manager,
  ../waku_message,
  ../waku_relay

export waku_message

const
  MaxRpcSize* = MaxWakuMessageSize + 64*1024 # We add a 64kB safety buffer for protocol overhead

type
  PushRequest* = object
    pubSubTopic*: string
    message*: WakuMessage

  PushResponse* = object
    isSuccess*: bool
    info*: string

  PushRPC* = object
    requestId*: string
    request*: PushRequest
    response*: PushResponse

  PushResponseHandler* = proc(response: PushResponse) {.gcsafe, closure.}

  PushRequestHandler* = proc(requestId: string, msg: PushRequest) {.gcsafe, closure.}

  WakuLightPush* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    peerManager*: PeerManager
    requestHandler*: PushRequestHandler
    relayReference*: WakuRelay
