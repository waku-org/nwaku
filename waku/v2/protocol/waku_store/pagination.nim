## Contains types and utilities for pagination.
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/byteutils,
  nimcrypto/sha2
import
  ../waku_message,
  ../../utils/time

const
  MaxPageSize*: uint64 = 100
  
  DefaultPageSize*: uint64 = 20 # A recommended default number of waku messages per page


type MessageDigest* = MDigest[256]

type PagingIndex* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  pubsubTopic*: string
  senderTime*: Timestamp # the time at which the message is generated
  receiverTime*: Timestamp
  digest*: MessageDigest # calculated over payload and content topic

proc computeDigest*(msg: WakuMessage): MessageDigest =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.payload)

  # Computes the hash
  return ctx.finish()

proc compute*(T: type PagingIndex, msg: WakuMessage, receivedTime: Timestamp, pubsubTopic: string): T =
  ## Takes a WakuMessage with received timestamp and returns its Index.
  let
    digest = computeDigest(msg)
    senderTime = msg.timestamp

  PagingIndex(
    pubsubTopic: pubsubTopic,
    senderTime: senderTime,
    receiverTime: receivedTime, 
    digest: digest
  )

proc `==`*(x, y: PagingIndex): bool =
  ## receiverTime plays no role in index equality
  (x.senderTime == y.senderTime) and
  (x.digest == y.digest) and
  (x.pubsubTopic == y.pubsubTopic)


type
  PagingDirection* {.pure.} = enum
    ## PagingDirection determines the direction of pagination
    BACKWARD = uint32(0)
    FORWARD = uint32(1)

  PagingInfo* = object
    ## This type holds the information needed for the pagination
    pageSize*: uint64
    cursor*: PagingIndex
    direction*: PagingDirection
