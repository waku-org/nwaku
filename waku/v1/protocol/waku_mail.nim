#
#            Waku Mail Client & Server
#              (c) Copyright 2018-2021
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)F
#            MIT license (LICENSE-MIT)
#

{.push raises: [Defect].}

import
  chronos,
  eth/[p2p, async_utils],
  ./waku_protocol

const
  requestCompleteTimeout = chronos.seconds(5)

type
  Cursor = seq[byte]

  MailRequest* = object
    lower*: uint32 ## Unix timestamp; oldest requested envelope's creation time
    upper*: uint32 ## Unix timestamp; newest requested envelope's creation time
    bloom*: seq[byte] ## Bloom filter to apply on the envelopes
    limit*: uint32 ## Maximum amount of envelopes to return
    cursor*: Cursor ## Optional cursor

proc requestMail*(node: EthereumNode, peerId: NodeId, request: MailRequest,
    symKey: SymKey, requests = 10): Future[Option[Cursor]] {.async.} =
  ## Send p2p mail request and check request complete.
  ## If result is none, and error occured. If result is a none empty cursor,
  ## more envelopes are available.
  # TODO: Perhaps don't go the recursive route or could use the actual response
  # proc to implement this (via a handler) and store the necessary data in the
  # WakuPeer object.
  # TODO: Several requestMail calls in parallel can create issues with handling
  # the wrong response to a request. Can additionaly check the requestId but
  # that would only solve it half. Better to use the requestResponse mechanism.

  # TODO: move this check out of requestMail?
  let peer = node.getPeer(peerId, Waku)
  if not peer.isSome():
    error "Invalid peer"
    return result
  elif not peer.get().state(Waku).trusted:
    return result

  var writer = initRlpWriter()
  writer.append(request)
  let payload = writer.finish()
  let data = encode(node.rng[], Payload(payload: payload, symKey: some(symKey)))
  if not data.isSome():
    error "Encoding of payload failed"
    return result

  # TODO: should this envelope be valid in terms of ttl, PoW, etc.?
  let env = Envelope(expiry:0, ttl: 0, data: data.get(), nonce: 0)
  # Send the request
  traceAsyncErrors peer.get().p2pRequest(env)

  # Wait for the Request Complete packet
  var f = peer.get().nextMsg(Waku.p2pRequestComplete)
  if await f.withTimeout(requestCompleteTimeout):
    let response = f.read()
    # TODO: I guess the idea is to check requestId (Hash) also?
    let requests = requests - 1
    # If there is cursor data, do another request
    if response.cursor.len > 0 and requests > 0:
      var newRequest = request
      newRequest.cursor = response.cursor
      return await requestMail(node, peerId, newRequest, symKey, requests)
    else:
      return some(response.cursor)
  else:
    error "p2pRequestComplete timeout"
    return result

proc p2pRequestHandler(peer: Peer, envelope: Envelope) =
  # Mail server p2p request implementation
  discard

proc enableMailServer*(node: EthereumNode) =
  # TODO: This could become part of an init call for an actual `MailServer`
  # object.
  node.registerP2PRequestHandler(p2pRequestHandler)
