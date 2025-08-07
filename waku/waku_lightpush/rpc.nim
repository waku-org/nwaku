{.push raises: [].}

import std/options
import ../waku_core
import ../incentivization/rpc

type LightPushStatusCode* = distinct uint32
proc `==`*(a, b: LightPushStatusCode): bool {.borrow.}
proc `$`*(code: LightPushStatusCode): string {.borrow.}

type
  LightpushRequest* = object
    requestId*: string
    pubSubTopic*: Option[PubsubTopic]
    message*: WakuMessage
    eligibilityProof*: Option[EligibilityProof]

  LightPushResponse* = object
    requestId*: string
    statusCode*: LightPushStatusCode
    statusDesc*: Option[string]
    relayPeerCount*: Option[uint32]
