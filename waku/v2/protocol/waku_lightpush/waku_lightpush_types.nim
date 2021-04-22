import
  std/[tables],
  bearssl,
  libp2p/peerinfo,
  libp2p/protocols/protocol,
  ../../node/peer_manager/peer_manager,
  ../waku_message

export waku_message

type
  PushRequest* = object
    pubsubTopic*: string
    message*: WakuMessage

  PushResponse* = object
    isSuccess*: bool
    info*: string

  PushRPC* = object
    requestId*: string
    request*: PushRequest
    push*: PushResponse

  WakuLightPush* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    peerManager*: PeerManager
