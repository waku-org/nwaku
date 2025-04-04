{.push raises: [].}

import std/options
import ../waku_core
import ../incentivization/rpc

type
  LightpushRequest* = object
    requestId*: string
    pubSubTopic*: Option[PubsubTopic]
    message*: WakuMessage
    eligibilityProof*: Option[EligibilityProof]

  LightPushResponse* = object
    requestId*: string
    statusCode*: uint32
    statusDesc*: Option[string]
    relayPeerCount*: Option[uint32]
