
## Generated at line 228
type
  Waku* = object
template State*(PROTO: type Waku): type =
  ref[WakuPeer:ObjectType]

template NetworkState*(PROTO: type Waku): type =
  ref[WakuNetwork:ObjectType]

type
  statusObj* = object
    options*: StatusOptions

template status*(PROTO: type Waku): type =
  statusObj

template msgProtocol*(MSG: type statusObj): type =
  Waku

template RecType*(MSG: type statusObj): untyped =
  statusObj

template msgId*(MSG: type statusObj): int =
  0

type
  messagesObj* = object
    envelopes*: seq[Envelope]

template messages*(PROTO: type Waku): type =
  messagesObj

template msgProtocol*(MSG: type messagesObj): type =
  Waku

template RecType*(MSG: type messagesObj): untyped =
  messagesObj

template msgId*(MSG: type messagesObj): int =
  1

type
  statusOptionsObj* = object
    options*: StatusOptions

template statusOptions*(PROTO: type Waku): type =
  statusOptionsObj

template msgProtocol*(MSG: type statusOptionsObj): type =
  Waku

template RecType*(MSG: type statusOptionsObj): untyped =
  statusOptionsObj

template msgId*(MSG: type statusOptionsObj): int =
  22

type
  p2pRequestObj* = object
    envelope*: Envelope

template p2pRequest*(PROTO: type Waku): type =
  p2pRequestObj

template msgProtocol*(MSG: type p2pRequestObj): type =
  Waku

template RecType*(MSG: type p2pRequestObj): untyped =
  p2pRequestObj

template msgId*(MSG: type p2pRequestObj): int =
  126

type
  p2pMessageObj* = object
    envelopes*: seq[Envelope]

template p2pMessage*(PROTO: type Waku): type =
  p2pMessageObj

template msgProtocol*(MSG: type p2pMessageObj): type =
  Waku

template RecType*(MSG: type p2pMessageObj): untyped =
  p2pMessageObj

template msgId*(MSG: type p2pMessageObj): int =
  127

type
  batchAcknowledgedObj* = object
  
template batchAcknowledged*(PROTO: type Waku): type =
  batchAcknowledgedObj

template msgProtocol*(MSG: type batchAcknowledgedObj): type =
  Waku

template RecType*(MSG: type batchAcknowledgedObj): untyped =
  batchAcknowledgedObj

template msgId*(MSG: type batchAcknowledgedObj): int =
  11

type
  messageResponseObj* = object
  
template messageResponse*(PROTO: type Waku): type =
  messageResponseObj

template msgProtocol*(MSG: type messageResponseObj): type =
  Waku

template RecType*(MSG: type messageResponseObj): untyped =
  messageResponseObj

template msgId*(MSG: type messageResponseObj): int =
  12

type
  p2pSyncResponseObj* = object
  
template p2pSyncResponse*(PROTO: type Waku): type =
  p2pSyncResponseObj

template msgProtocol*(MSG: type p2pSyncResponseObj): type =
  Waku

template RecType*(MSG: type p2pSyncResponseObj): untyped =
  p2pSyncResponseObj

template msgId*(MSG: type p2pSyncResponseObj): int =
  124

type
  p2pSyncRequestObj* = object
  
template p2pSyncRequest*(PROTO: type Waku): type =
  p2pSyncRequestObj

template msgProtocol*(MSG: type p2pSyncRequestObj): type =
  Waku

template RecType*(MSG: type p2pSyncRequestObj): untyped =
  p2pSyncRequestObj

template msgId*(MSG: type p2pSyncRequestObj): int =
  123

type
  p2pRequestCompleteObj* = object
    requestId*: Hash
    lastEnvelopeHash*: Hash
    cursor*: seq[byte]

template p2pRequestComplete*(PROTO: type Waku): type =
  p2pRequestCompleteObj

template msgProtocol*(MSG: type p2pRequestCompleteObj): type =
  Waku

template RecType*(MSG: type p2pRequestCompleteObj): untyped =
  p2pRequestCompleteObj

template msgId*(MSG: type p2pRequestCompleteObj): int =
  125

var WakuProtocolObj = initProtocol("waku", 1, createPeerState[Peer,
    ref[WakuPeer:ObjectType]], createNetworkState[EthereumNode,
    ref[WakuNetwork:ObjectType]])
var WakuProtocol = addr WakuProtocolObj
template protocolInfo*(PROTO: type Waku): auto =
  WakuProtocol

proc statusRawSender(peerOrResponder: Peer; options: StatusOptions;
                    timeout: Duration = milliseconds(10000'i64)): Future[void] {.
    gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 0
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 0)
  append(writer, perPeerMsgId)
  append(writer, options)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

template status*(peer: Peer; options: StatusOptions;
                timeout: Duration = milliseconds(10000'i64)): Future[statusObj] =
  let peer_184785056 = peer
  let sendingFuture`gensym184785057 = statusRawSender(peer, options)
  handshakeImpl(peer_184785056, sendingFuture`gensym184785057,
                nextMsg(peer_184785056, statusObj), timeout)

proc messages*(peerOrResponder: Peer; envelopes: openarray[Envelope]): Future[void] {.
    gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 1
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 1)
  append(writer, perPeerMsgId)
  append(writer, envelopes)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc statusOptions*(peerOrResponder: Peer; options: StatusOptions): Future[void] {.
    gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 22
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 22)
  append(writer, perPeerMsgId)
  append(writer, options)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc p2pRequest*(peerOrResponder: Peer; envelope: Envelope): Future[void] {.gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 126
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 126)
  append(writer, perPeerMsgId)
  append(writer, envelope)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc p2pMessage*(peerOrResponder: Peer; envelopes: openarray[Envelope]): Future[void] {.
    gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 127
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 127)
  append(writer, perPeerMsgId)
  append(writer, envelopes)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc batchAcknowledged*(peerOrResponder: Peer): Future[void] {.gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 11
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 11)
  append(writer, perPeerMsgId)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc messageResponse*(peerOrResponder: Peer): Future[void] {.gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 12
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 12)
  append(writer, perPeerMsgId)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc p2pSyncResponse*(peerOrResponder: ResponderWithId[p2pSyncResponseObj]): Future[
    void] {.gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 124
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 124)
  append(writer, perPeerMsgId)
  append(writer, peerOrResponder.reqId)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

template send*(r`gensym184785072: ResponderWithId[p2pSyncResponseObj];
              args`gensym184785073: varargs[untyped]): auto =
  p2pSyncResponse(r`gensym184785072, args`gensym184785073)

proc p2pSyncRequest*(peerOrResponder: Peer;
                    timeout: Duration = milliseconds(10000'i64)): Future[
    Option[p2pSyncResponseObj]] {.gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 123
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 123)
  append(writer, perPeerMsgId)
  initFuture result
  let reqId = registerRequest(peer, timeout, result, perPeerMsgId + 1)
  append(writer, reqId)
  let msgBytes = finish(writer)
  linkSendFailureToReqFuture(sendMsg(peer, msgBytes), result)

proc p2pRequestComplete*(peerOrResponder: Peer; requestId: Hash;
                        lastEnvelopeHash: Hash; cursor: seq[byte]): Future[void] {.
    gcsafe.} =
  let peer = getPeer(peerOrResponder)
  var writer = initRlpWriter()
  const
    perProtocolMsgId = 125
  let perPeerMsgId = perPeerMsgIdImpl(peer, WakuProtocol, 125)
  append(writer, perPeerMsgId)
  startList(writer, 3)
  append(writer, requestId)
  append(writer, lastEnvelopeHash)
  append(writer, cursor)
  let msgBytes = finish(writer)
  return sendMsg(peer, msgBytes)

proc messagesUserHandler(peer: Peer; envelopes: seq[Envelope]) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 1
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  if not peer.state.initialized:
    warn "Handshake not completed yet, discarding messages"
    return
  for envelope in envelopes:
    if not envelope.valid():
      warn "Expired or future timed envelope", peer
      continue
    peer.state.accounting.received += 1
    let msg = initMessage(envelope)
    if not msg.allowed(peer.networkState.config):
      continue
    if peer.state.received.containsOrIncl(msg.hash):
      envelopes_dropped.inc(labelValues = ["duplicate"])
      trace "Peer sending duplicate messages", peer, hash = $msg.hash
      continue
    if peer.networkState.queue[].add(msg):
      peer.networkState.filters.notify(msg)

proc statusOptionsUserHandler(peer: Peer; options: StatusOptions) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 22
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  if not peer.state.initialized:
    warn "Handshake not completed yet, discarding statusOptions"
    return
  if options.topicInterest.isSome():
    peer.state.topics = options.topicInterest
  elif options.bloomFilter.isSome():
    peer.state.bloom = options.bloomFilter.get()
    peer.state.topics = none(seq[Topic])
  if options.powRequirement.isSome():
    peer.state.powRequirement = options.powRequirement.get()
  if options.lightNode.isSome():
    peer.state.isLightNode = options.lightNode.get()

proc p2pRequestUserHandler(peer: Peer; envelope: Envelope) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 126
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  if not peer.networkState.p2pRequestHandler.isNil():
    peer.networkState.p2pRequestHandler(peer, envelope)

proc p2pMessageUserHandler(peer: Peer; envelopes: seq[Envelope]) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 127
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  if peer.state.trusted:
    for envelope in envelopes:
      let msg = Message(env: envelope, isP2P: true)
      peer.networkState.filters.notify(msg)

proc batchAcknowledgedUserHandler(peer: Peer) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 11
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  discard

proc messageResponseUserHandler(peer: Peer) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 12
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  discard

proc p2pSyncResponseUserHandler(peer: Peer; reqId: int) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 124
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  discard

proc p2pSyncRequestUserHandler(peer: Peer; reqId: int) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 123
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  var response = init(ResponderWithId[p2pSyncResponseObj], peer, reqId)
  discard

proc p2pRequestCompleteUserHandler(peer: Peer; requestId: Hash;
                                  lastEnvelopeHash: Hash; cursor: seq[byte]) {.
    gcsafe, async.} =
  type
    CurrentProtocol = Waku
  const
    perProtocolMsgId = 125
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  discard

proc statusThunk(peer: Peer; _`gensym184785033: int; data`gensym184785034: Rlp) {.
    async, gcsafe.} =
  var rlp = data`gensym184785034
  var msg {.noinit.}: statusObj
  msg.options = checkedRlpRead(peer, rlp, StatusOptions)
  
proc messagesThunk(peer: Peer; _`gensym184785058: int; data`gensym184785059: Rlp) {.
    async, gcsafe.} =
  var rlp = data`gensym184785059
  var msg {.noinit.}: messagesObj
  msg.envelopes = checkedRlpRead(peer, rlp, openarray[Envelope])
  await(messagesUserHandler(peer, msg.envelopes))
  
proc statusOptionsThunk(peer: Peer; _`gensym184785060: int; data`gensym184785061: Rlp) {.
    async, gcsafe.} =
  var rlp = data`gensym184785061
  var msg {.noinit.}: statusOptionsObj
  msg.options = checkedRlpRead(peer, rlp, StatusOptions)
  await(statusOptionsUserHandler(peer, msg.options))
  
proc p2pRequestThunk(peer: Peer; _`gensym184785062: int; data`gensym184785063: Rlp) {.
    async, gcsafe.} =
  var rlp = data`gensym184785063
  var msg {.noinit.}: p2pRequestObj
  msg.envelope = checkedRlpRead(peer, rlp, Envelope)
  await(p2pRequestUserHandler(peer, msg.envelope))
  
proc p2pMessageThunk(peer: Peer; _`gensym184785064: int; data`gensym184785065: Rlp) {.
    async, gcsafe.} =
  var rlp = data`gensym184785065
  var msg {.noinit.}: p2pMessageObj
  msg.envelopes = checkedRlpRead(peer, rlp, openarray[Envelope])
  await(p2pMessageUserHandler(peer, msg.envelopes))
  
proc batchAcknowledgedThunk(peer: Peer; _`gensym184785066: int;
                           data`gensym184785067: Rlp) {.async, gcsafe.} =
  var rlp = data`gensym184785067
  var msg {.noinit.}: batchAcknowledgedObj
  await(batchAcknowledgedUserHandler(peer))
  
proc messageResponseThunk(peer: Peer; _`gensym184785068: int;
                         data`gensym184785069: Rlp) {.async, gcsafe.} =
  var rlp = data`gensym184785069
  var msg {.noinit.}: messageResponseObj
  await(messageResponseUserHandler(peer))
  
proc p2pSyncResponseThunk(peer: Peer; _`gensym184785070: int;
                         data`gensym184785071: Rlp) {.async, gcsafe.} =
  var rlp = data`gensym184785071
  var msg {.noinit.}: p2pSyncResponseObj
  let reqId = read(rlp, int)
  await(p2pSyncResponseUserHandler(peer, reqId))
  resolveResponseFuture(peer, perPeerMsgId(peer, p2pSyncResponseObj), addr(msg),
                        reqId)

proc p2pSyncRequestThunk(peer: Peer; _`gensym184785074: int;
                        data`gensym184785075: Rlp) {.async, gcsafe.} =
  var rlp = data`gensym184785075
  var msg {.noinit.}: p2pSyncRequestObj
  let reqId = read(rlp, int)
  await(p2pSyncRequestUserHandler(peer, reqId))
  
proc p2pRequestCompleteThunk(peer: Peer; _`gensym184785076: int;
                            data`gensym184785077: Rlp) {.async, gcsafe.} =
  var rlp = data`gensym184785077
  var msg {.noinit.}: p2pRequestCompleteObj
  tryEnterList(rlp)
  msg.requestId = checkedRlpRead(peer, rlp, Hash)
  msg.lastEnvelopeHash = checkedRlpRead(peer, rlp, Hash)
  msg.cursor = checkedRlpRead(peer, rlp, seq[byte])
  await(p2pRequestCompleteUserHandler(peer, msg.requestId, msg.lastEnvelopeHash,
                                      msg.cursor))
  
registerMsg(WakuProtocol, 0, "status", statusThunk, messagePrinter[statusObj],
            requestResolver[statusObj], nextMsgResolver[statusObj])
registerMsg(WakuProtocol, 1, "messages", messagesThunk, messagePrinter[messagesObj],
            requestResolver[messagesObj], nextMsgResolver[messagesObj])
registerMsg(WakuProtocol, 22, "statusOptions", statusOptionsThunk,
            messagePrinter[statusOptionsObj], requestResolver[statusOptionsObj],
            nextMsgResolver[statusOptionsObj])
registerMsg(WakuProtocol, 126, "p2pRequest", p2pRequestThunk,
            messagePrinter[p2pRequestObj], requestResolver[p2pRequestObj],
            nextMsgResolver[p2pRequestObj])
registerMsg(WakuProtocol, 127, "p2pMessage", p2pMessageThunk,
            messagePrinter[p2pMessageObj], requestResolver[p2pMessageObj],
            nextMsgResolver[p2pMessageObj])
registerMsg(WakuProtocol, 11, "batchAcknowledged", batchAcknowledgedThunk,
            messagePrinter[batchAcknowledgedObj],
            requestResolver[batchAcknowledgedObj],
            nextMsgResolver[batchAcknowledgedObj])
registerMsg(WakuProtocol, 12, "messageResponse", messageResponseThunk,
            messagePrinter[messageResponseObj],
            requestResolver[messageResponseObj],
            nextMsgResolver[messageResponseObj])
registerMsg(WakuProtocol, 124, "p2pSyncResponse", p2pSyncResponseThunk,
            messagePrinter[p2pSyncResponseObj],
            requestResolver[p2pSyncResponseObj],
            nextMsgResolver[p2pSyncResponseObj])
registerMsg(WakuProtocol, 123, "p2pSyncRequest", p2pSyncRequestThunk,
            messagePrinter[p2pSyncRequestObj],
            requestResolver[p2pSyncRequestObj],
            nextMsgResolver[p2pSyncRequestObj])
registerMsg(WakuProtocol, 125, "p2pRequestComplete", p2pRequestCompleteThunk,
            messagePrinter[p2pRequestCompleteObj],
            requestResolver[p2pRequestCompleteObj],
            nextMsgResolver[p2pRequestCompleteObj])
proc WakuPeerConnected(peer: Peer) {.gcsafe, async.} =
  type
    CurrentProtocol = Waku
  template state(peer: Peer): ref[WakuPeer:ObjectType] =
    cast[ref[WakuPeer:ObjectType]](getState(peer, WakuProtocol))

  template networkState(peer: Peer): ref[WakuNetwork:ObjectType] =
    cast[ref[WakuNetwork:ObjectType]](getNetworkState(peer.network, WakuProtocol))

  trace "onPeerConnected Waku"
  let
    wakuNet = peer.networkState
    wakuPeer = peer.state
  let options = StatusOptions(powRequirement: some(wakuNet.config.powRequirement),
                           bloomFilter: wakuNet.config.bloom,
                           lightNode: some(wakuNet.config.isLightNode), confirmationsEnabled: some(
      wakuNet.config.confirmationsEnabled),
                           rateLimits: wakuNet.config.rateLimits,
                           topicInterest: wakuNet.config.topics)
  let m = await peer.status(options, timeout = chronos.milliseconds(5000))
  wakuPeer.powRequirement = m.options.powRequirement.get(defaultMinPow)
  wakuPeer.bloom = m.options.bloomFilter.get(fullBloom())
  wakuPeer.isLightNode = m.options.lightNode.get(false)
  if wakuPeer.isLightNode and wakuNet.config.isLightNode:
    raise newException(UselessPeerError, "Two light nodes connected")
  wakuPeer.topics = m.options.topicInterest
  if wakuPeer.topics.isSome():
    if wakuPeer.topics.get().len > topicInterestMax:
      raise newException(UselessPeerError, "Topic-interest is too large")
    if wakuNet.config.topics.isSome():
      raise newException(UselessPeerError,
                        "Two Waku nodes with topic-interest connected")
  wakuPeer.received.init()
  wakuPeer.trusted = false
  wakuPeer.accounting = Accounting(sent: 0, received: 0)
  wakuPeer.initialized = true
  if not wakuNet.config.isLightNode:
    traceAsyncErrors peer.run()
  debug "Waku peer initialized", peer

setEventHandlers(WakuProtocol, WakuPeerConnected, nil)
registerProtocol(WakuProtocol)