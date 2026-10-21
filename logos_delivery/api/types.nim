{.push raises: [].}

import libp2p/crypto/crypto, bearssl/rand, std/times, chronos
import std/strutils
import results, stew/byteutils
import logos_delivery/waku/utils/requests as request_utils
import logos_delivery/waku/waku_core/[topics/content_topic, message/message, time]

export content_topic, message

type
  MessagePriority* {.pure.} = enum
    ## Application-level send priority. Accepted and carried, not yet acted on.
    Low
    Medium
    High

  MessageEnvelope* = object
    contentTopic*: ContentTopic
    payload*: seq[byte]
    ephemeral*: bool
    priority*: MessagePriority
    meta*: seq[byte]
      ## Opaque wire-format marker carried on the underlying WakuMessage.
      ## Higher layers (e.g. Reliable Channel) stamp this so peers can route
      ## ingress traffic to their corresponding layer. Empty by default.

  RequestId* = distinct string

  ConnectionStatus* {.pure.} = enum
    Disconnected
    PartiallyConnected
    Connected

  MessageSource* {.pure.} = enum
    Live = "live" ## delivered as it was published, over relay or filter
    History = "history" ## recovered from a Store peer, at start or after a gap

  PeerConnInfo* = object ## structured connected-peer info for the api boundary
    peerId*: string
    protocols*: seq[string]
    addresses*: seq[string]

proc parseMessagePriority*(s: string): Result[MessagePriority, string] =
  case s.toLowerAscii()
  of "low":
    return ok(MessagePriority.Low)
  of "medium":
    return ok(MessagePriority.Medium)
  of "high":
    return ok(MessagePriority.High)
  else:
    return err("invalid message priority, expected low|medium|high: " & s)

proc new*(T: typedesc[RequestId], rng: crypto.Rng): T =
  ## Generate a new RequestId using the provided RNG.
  RequestId(request_utils.generateRequestId(rng))

proc `$`*(r: RequestId): string {.inline.} =
  string(r)

proc `==`*(a, b: RequestId): bool {.inline.} =
  string(a) == string(b)

proc init*(
    T: type MessageEnvelope,
    contentTopic: ContentTopic,
    payload: seq[byte] | string,
    ephemeral: bool = false,
    meta: seq[byte] = @[],
    priority: MessagePriority = MessagePriority.Medium,
): MessageEnvelope =
  when payload is seq[byte]:
    MessageEnvelope(
      contentTopic: contentTopic,
      payload: payload,
      ephemeral: ephemeral,
      priority: priority,
      meta: meta,
    )
  else:
    MessageEnvelope(
      contentTopic: contentTopic,
      payload: payload.toBytes(),
      ephemeral: ephemeral,
      priority: priority,
      meta: meta,
    )

proc toWakuMessage*(envelope: MessageEnvelope): WakuMessage =
  ## Convert a MessageEnvelope to a WakuMessage.
  var wm = WakuMessage(
    contentTopic: envelope.contentTopic,
    payload: envelope.payload,
    ephemeral: envelope.ephemeral,
    meta: envelope.meta,
    timestamp: getNowInNanosecondTime(),
  )

  ## The send path (attachRlnProof) attaches the proof; its epoch derives from this timestamp.
  return wm

{.pop.}
