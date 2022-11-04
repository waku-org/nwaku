#
#                 Waku
#              (c) Copyright 2018-2021
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)
#

## Waku
## *******
##
## Waku is a fork of Whisper.
##
## Waku is a gossip protocol that synchronizes a set of messages across nodes
## with attention given to sender and recipient anonymitiy. Messages are
## categorized by a topic and stay alive in the network based on a time-to-live
## measured in seconds. Spam prevention is based on proof-of-work, where large
## or long-lived messages must spend more work.
##
## Implementation should be according to Waku specification defined here:
## https://github.com/vacp2p/specs/blob/master/waku/waku.md
##
## Example usage
## ----------
## First an `EthereumNode` needs to be created, either with all capabilities set
## or with specifically the Waku capability set.
## The latter can be done like this:
##
##   .. code-block::nim
##      var node = newEthereumNode(keypair, address, netId, nil,
##                                 addAllCapabilities = false)
##      node.addCapability Waku
##
## Now calls such as ``postMessage`` and ``subscribeFilter`` can be done.
## However, they only make real sense after ``connectToNetwork`` was started. As
## else there will be no peers to send and receive messages from.

{.push raises: [Defect].}

import
  options, tables, times, chronos, chronicles, metrics,
  eth/[keys, async_utils, p2p],
  ../../whisper/whisper_types,
  eth/trie/trie_defs

export
  whisper_types

logScope:
  topics = "waku"

const
  defaultQueueCapacity = 2048
  wakuVersion* = 1 ## Waku version.
  wakuVersionStr* = $wakuVersion ## Waku version.
  defaultMinPow* = 0.2'f64 ## The default minimum PoW requirement for this node.
  defaultMaxMsgSize* = 1024'u32 * 1024'u32 ## The current default and max
  ## message size. This can never be larger than the maximum RLPx message size.
  messageInterval* = chronos.milliseconds(300) ## Interval at which messages are
  ## send to peers, in ms.
  pruneInterval* = chronos.milliseconds(1000)  ## Interval at which message
  ## queue is pruned, in ms.
  topicInterestMax = 10000

type
  WakuConfig* = object
    powRequirement*: float64
    bloom*: Option[Bloom]
    isLightNode*: bool
    maxMsgSize*: uint32
    confirmationsEnabled*: bool
    rateLimits*: Option[RateLimits]
    topics*: Option[seq[whisper_types.Topic]]

  Accounting* = ref object
    sent*: uint
    received*: uint

  WakuPeer = ref object
    initialized: bool # when successfully completed the handshake
    powRequirement*: float64
    bloom*: Bloom
    isLightNode*: bool
    trusted*: bool
    topics*: Option[seq[whisper_types.Topic]]
    received: HashSet[Hash]
    accounting*: Accounting

  P2PRequestHandler* = proc(peer: Peer, envelope: Envelope)
    {.gcsafe, raises: [Defect].}

  EnvReceivedHandler* = proc(envelope: Envelope) {.gcsafe, raises: [Defect].}

  WakuNetwork = ref object
    queue*: ref Queue
    filters*: Filters
    config*: WakuConfig
    p2pRequestHandler*: P2PRequestHandler
    envReceivedHandler*: EnvReceivedHandler

  RateLimits* = object
    # TODO: uint or specifically uint32?
    limitIp*: uint
    limitPeerId*: uint
    limitTopic*: uint

  StatusOptions* = object
    powRequirement*: Option[(float64)]
    bloomFilter*: Option[Bloom]
    lightNode*: Option[bool]
    confirmationsEnabled*: Option[bool]
    rateLimits*: Option[RateLimits]
    topicInterest*: Option[seq[whisper_types.Topic]]

  KeyKind* = enum
    powRequirementKey,
    bloomFilterKey,
    lightNodeKey,
    confirmationsEnabledKey,
    rateLimitsKey,
    topicInterestKey

template countSomeFields*(x: StatusOptions): int =
  var count = 0
  for f in fields(x):
    if f.isSome():
      inc count
  count

proc append*(rlpWriter: var RlpWriter, value: StatusOptions) =
  var list = initRlpList(countSomeFields(value))
  if value.powRequirement.isSome():
    list.append((powRequirementKey, cast[uint64](value.powRequirement.get())))
  if value.bloomFilter.isSome():
    list.append((bloomFilterKey, @(value.bloomFilter.get())))
  if value.lightNode.isSome():
    list.append((lightNodeKey, value.lightNode.get()))
  if value.confirmationsEnabled.isSome():
    list.append((confirmationsEnabledKey, value.confirmationsEnabled.get()))
  if value.rateLimits.isSome():
    list.append((rateLimitsKey, value.rateLimits.get()))
  if value.topicInterest.isSome():
    list.append((topicInterestKey, value.topicInterest.get()))

  let bytes = list.finish()

  try:
    rlpWriter.append(rlpFromBytes(bytes))
  except RlpError as e:
    # bytes is valid rlp just created here, rlpFromBytes should thus never fail
    raiseAssert e.msg

proc read*(rlp: var Rlp, T: typedesc[StatusOptions]):
    T {.raises: [RlpError, Defect].}=
  if not rlp.isList():
    raise newException(RlpTypeMismatch,
      "List expected, but the source RLP is not a list.")

  let sz = rlp.listLen()
  # We already know that we are working with a list
  doAssert rlp.enterList()
  for i in 0 ..< sz:
    rlp.tryEnterList()

    var k: KeyKind
    try:
      k = rlp.read(KeyKind)
    except RlpTypeMismatch:
      # skip unknown keys and their value
      rlp.skipElem()
      rlp.skipElem()
      continue

    case k
    of powRequirementKey:
      let pow = rlp.read(uint64)
      result.powRequirement = some(cast[float64](pow))
    of bloomFilterKey:
      let bloom = rlp.read(seq[byte])
      if bloom.len != bloomSize:
        raise newException(RlpTypeMismatch, "Bloomfilter size mismatch")
      var bloomFilter: Bloom
      bloomFilter.bytesCopy(bloom)
      result.bloomFilter = some(bloomFilter)
    of lightNodeKey:
      result.lightNode = some(rlp.read(bool))
    of confirmationsEnabledKey:
      result.confirmationsEnabled = some(rlp.read(bool))
    of rateLimitsKey:
      result.rateLimits = some(rlp.read(RateLimits))
    of topicInterestKey:
      result.topicInterest = some(rlp.read(seq[whisper_types.Topic]))

proc allowed*(msg: Message, config: WakuConfig): bool =
  # Check max msg size, already happens in RLPx but there is a specific waku
  # max msg size which should always be < RLPx max msg size
  if msg.size > config.maxMsgSize:
    envelopes_dropped.inc(labelValues = ["too_large"])
    warn "Message size too large", size = msg.size
    return false

  if msg.pow < config.powRequirement:
    envelopes_dropped.inc(labelValues = ["low_pow"])
    warn "Message PoW too low", pow = msg.pow, minPow = config.powRequirement
    return false

  if config.topics.isSome():
    if msg.env.topic notin config.topics.get():
      envelopes_dropped.inc(labelValues = ["topic_mismatch"])
      warn "Message topic does not match Waku topic list"
      return false
  else:
    if config.bloom.isSome() and not bloomFilterMatch(config.bloom.get(), msg.bloom):
      envelopes_dropped.inc(labelValues = ["bloom_filter_mismatch"])
      warn "Message does not match node bloom filter"
      return false

  return true

proc run(peer: Peer) {.gcsafe, async, raises: [Defect].}
proc run(node: EthereumNode, network: WakuNetwork)
  {.gcsafe, async, raises: [Defect].}

proc initProtocolState*(network: WakuNetwork, node: EthereumNode) {.gcsafe.} =
  new(network.queue)
  network.queue[] = initQueue(defaultQueueCapacity)
  network.filters = initTable[string, Filter]()
  network.config.bloom = some(fullBloom())
  network.config.powRequirement = defaultMinPow
  network.config.isLightNode = false
  # RateLimits and confirmations are not yet implemented so we set confirmations
  # to false and we don't pass RateLimits at all.
  network.config.confirmationsEnabled = false
  network.config.rateLimits = none(RateLimits)
  network.config.maxMsgSize = defaultMaxMsgSize
  network.config.topics = none(seq[whisper_types.Topic])
  asyncSpawn node.run(network)

p2pProtocol Waku(version = wakuVersion,
                 rlpxName = "waku",
                 peerState = WakuPeer,
                 networkState = WakuNetwork):

  onPeerConnected do (peer: Peer):
    trace "onPeerConnected Waku"
    let
      wakuNet = peer.networkState
      wakuPeer = peer.state

    let options = StatusOptions(
      powRequirement: some(wakuNet.config.powRequirement),
      bloomFilter: wakuNet.config.bloom,
      lightNode: some(wakuNet.config.isLightNode),
      confirmationsEnabled: some(wakuNet.config.confirmationsEnabled),
      rateLimits: wakuNet.config.rateLimits,
      topicInterest: wakuNet.config.topics)

    let m = await peer.status(options,
      timeout = chronos.milliseconds(5000))

    wakuPeer.powRequirement = m.options.powRequirement.get(defaultMinPow)
    wakuPeer.bloom = m.options.bloomFilter.get(fullBloom())

    wakuPeer.isLightNode = m.options.lightNode.get(false)
    if wakuPeer.isLightNode and wakuNet.config.isLightNode:
      # No sense in connecting two light nodes so we disconnect
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

    # No timer based queue processing for a light node.
    if not wakuNet.config.isLightNode:
      asyncSpawn peer.run()

    debug "Waku peer initialized", peer

  handshake:
    proc status(peer: Peer, options: StatusOptions)

  proc messages(peer: Peer, envelopes: openarray[Envelope]) =
    if not peer.state.initialized:
      warn "Handshake not completed yet, discarding messages"
      return

    for envelope in envelopes:
      # check if expired or in future, or ttl not 0
      if not envelope.valid():
        warn "Expired or future timed envelope", peer
        # disconnect from peers sending bad envelopes
        # await peer.disconnect(SubprotocolReason)
        continue

      peer.state.accounting.received += 1

      let msg = initMessage(envelope)
      if not msg.allowed(peer.networkState.config):
        # disconnect from peers sending bad envelopes
        # await peer.disconnect(SubprotocolReason)
        continue

      # This peer send this message thus should not receive it again.
      # If this peer has the message in the `received` set already, this means
      # it was either already received here from this peer or send to this peer.
      # Either way it will be in our queue already (and the peer should know
      # this) and this peer is sending duplicates.
      # Note: geth does not check if a peer has send a message to them before
      # broadcasting this message. This too is seen here as a duplicate message
      # (see above comment). If we want to seperate these cases (e.g. when peer
      # rating), then we have to add a "peer.state.send" HashSet.
      # Note: it could also be a race between the arrival of a message send by
      # this node to a peer and that same message arriving from that peer (after
      # it was received from another peer) here.
      if peer.state.received.containsOrIncl(msg.hash):
        envelopes_dropped.inc(labelValues = ["duplicate"])
        trace "Peer sending duplicate messages", peer, hash = $msg.hash
        # await peer.disconnect(SubprotocolReason)
        continue

      # This can still be a duplicate message, but from another peer than
      # the peer who send the message.
      if peer.networkState.queue[].add(msg):
        # notify filters of this message
        peer.networkState.filters.notify(msg)
        # trigger handler on received envelope, if registered
        if not peer.networkState.envReceivedHandler.isNil():
          peer.networkState.envReceivedHandler(envelope)

  nextID 22

  proc statusOptions(peer: Peer, options: StatusOptions) =
    if not peer.state.initialized:
      warn "Handshake not completed yet, discarding statusOptions"
      return

    if options.topicInterest.isSome():
      peer.state.topics = options.topicInterest
    elif options.bloomFilter.isSome():
      peer.state.bloom = options.bloomFilter.get()
      peer.state.topics = none(seq[whisper_types.Topic])

    if options.powRequirement.isSome():
      peer.state.powRequirement = options.powRequirement.get()

    if options.lightNode.isSome():
      peer.state.isLightNode = options.lightNode.get()

  nextID 126

  proc p2pRequest(peer: Peer, envelope: Envelope) =
    if not peer.networkState.p2pRequestHandler.isNil():
      peer.networkState.p2pRequestHandler(peer, envelope)

  proc p2pMessage(peer: Peer, envelopes: openarray[Envelope]) =
    if peer.state.trusted:
      # when trusted we can bypass any checks on envelope
      for envelope in envelopes:
        let msg = Message(env: envelope, isP2P: true)
        peer.networkState.filters.notify(msg)

  # Following message IDs are not part of EIP-627, but are added and used by
  # the Status application, we ignore them for now.
  nextID 11
  proc batchAcknowledged(peer: Peer) = discard
  proc messageResponse(peer: Peer) = discard

  nextID 123
  requestResponse:
    proc p2pSyncRequest(peer: Peer) = discard
    proc p2pSyncResponse(peer: Peer) = discard


  proc p2pRequestComplete(peer: Peer, requestId: Hash, lastEnvelopeHash: Hash,
    cursor: seq[byte]) = discard
    # TODO:
    # In the current specification the parameters are not wrapped in a regular
    # envelope as is done for the P2P Request packet. If we could alter this in
    # the spec it would be a cleaner separation between Waku and Mail server /
    # client.
    # Also, if a requestResponse block is used, a reqestId will automatically
    # be added by the protocol DSL.
    # However the requestResponse block in combination with p2pRequest cannot be
    # used due to the unfortunate fact that the packet IDs are not consecutive,
    # and nextID is not recognized in between these. The nextID behaviour could
    # be fixed, however it would be cleaner if the specification could be
    # changed to have these IDs to be consecutive.

# 'Runner' calls ---------------------------------------------------------------

proc processQueue(peer: Peer) {.raises: [Defect].} =
  # Send to peer all valid and previously not send envelopes in the queue.
  var
    envelopes: seq[Envelope] = @[]
    wakuPeer = peer.state(Waku)
    wakuNet = peer.networkState(Waku)

  for message in wakuNet.queue.items:
    if wakuPeer.received.contains(message.hash):
      # trace "message was already send to peer", hash = $message.hash, peer
      continue

    if message.pow < wakuPeer.powRequirement:
      trace "Message PoW too low for peer", pow = message.pow,
                                            powReq = wakuPeer.powRequirement
      continue

    if wakuPeer.topics.isSome():
      if message.env.topic notin wakuPeer.topics.get():
        trace "Message does not match topics list"
        continue
    else:
      if not bloomFilterMatch(wakuPeer.bloom, message.bloom):
        trace "Message does not match peer bloom filter"
        continue

    trace "Adding envelope"
    envelopes.add(message.env)
    wakuPeer.accounting.sent += 1
    wakuPeer.received.incl(message.hash)

  if envelopes.len() > 0:
    trace "Sending envelopes", amount=envelopes.len
    # Ignore failure of sending messages, this could occur when the connection
    # gets dropped
    traceAsyncErrors peer.messages(envelopes)

proc run(peer: Peer) {.async, raises: [Defect].} =
  while peer.connectionState notin {Disconnecting, Disconnected}:
    peer.processQueue()
    await sleepAsync(messageInterval)

proc pruneReceived(node: EthereumNode) =
  if node.peerPool != nil: # XXX: a bit dirty to need to check for this here ...
    var wakuNet = node.protocolState(Waku)

    for peer in node.protocolPeers(Waku):
      if not peer.initialized:
        continue

      # NOTE: Perhaps alter the queue prune call to keep track of a HashSet
      # of pruned messages (as these should be smaller), and diff this with
      # the received sets.
      peer.received = intersection(peer.received, wakuNet.queue.itemHashes)

proc run(node: EthereumNode, network: WakuNetwork) {.async, raises: [Defect].} =
  while true:
    # prune message queue every second
    # TTL unit is in seconds, so this should be sufficient?
    network.queue[].prune()
    # pruning the received sets is not necessary for correct workings
    # but simply from keeping the sets growing indefinitely
    node.pruneReceived()
    await sleepAsync(pruneInterval)

# Private EthereumNode calls ---------------------------------------------------

proc sendP2PMessage(node: EthereumNode, peerId: NodeId,
    envelopes: openarray[Envelope]): bool =
  for peer in node.peers(Waku):
    if peer.remote.id == peerId:
      let f = peer.p2pMessage(envelopes)
      # Can't make p2pMessage not raise so this is the "best" option I can think
      # of instead of using asyncSpawn and still keeping the call not async.
      f.callback = proc(data: pointer) {.gcsafe, raises: [Defect].} =
        if f.failed:
          warn "P2PMessage send failed", msg = f.readError.msg

      return true

proc queueMessage(node: EthereumNode, msg: Message): bool =

  var wakuNet = node.protocolState(Waku)
  # We have to do the same checks here as in the messages proc not to leak
  # any information that the message originates from this node.
  if not msg.allowed(wakuNet.config):
    return false

  trace "Adding message to queue", hash = $msg.hash
  if wakuNet.queue[].add(msg):
    # Also notify our own filters of the message we are sending,
    # e.g. msg from local Dapp to Dapp
    wakuNet.filters.notify(msg)

  return true

# Public EthereumNode calls ----------------------------------------------------

proc postEncoded*(node: EthereumNode, ttl: uint32,
                  topic: whisper_types.Topic, encodedPayload: seq[byte],
                  powTime = 1'f,
                  powTarget = defaultMinPow,
                  targetPeer = none[NodeId]()): bool =
  ## Post a message from pre-encoded payload on the message queue.
  ## This will be processed at the next `messageInterval`.
  ## The encodedPayload must be encoded according to RFC 26/WAKU-PAYLOAD
  ## at https://rfc.vac.dev/spec/26/
  
  var env = Envelope(expiry:epochTime().uint32 + ttl,
                       ttl: ttl, topic: topic, data: encodedPayload, nonce: 0)

  # Allow lightnode to post only direct p2p messages
  if targetPeer.isSome():
    return node.sendP2PMessage(targetPeer.get(), [env])
  else:
    # non direct p2p message can not have ttl of 0
    if env.ttl == 0:
      return false
    var msg = initMessage(env, powCalc = false)
    # XXX: make this non blocking or not?
    # In its current blocking state, it could be noticed by a peer that no
    # messages are send for a while, and thus that mining PoW is done, and
    # that next messages contains a message originated from this peer
    # zah: It would be hard to execute this in a background thread at the
    # moment. We'll need a way to send custom "tasks" to the async message
    # loop (e.g. AD2 support for AsyncChannels).
    if not msg.sealEnvelope(powTime, powTarget):
      return false

    # need to check expiry after mining PoW
    if not msg.env.valid():
      return false

    result = node.queueMessage(msg)

    # Allows light nodes to post via untrusted messages packet.
    # Queue gets processed immediatly as the node sends only its own messages,
    # so the privacy ship has already sailed anyhow.
    # TODO:
    # - Could be still a concern in terms of efficiency, if multiple messages
    # need to be send.
    # - For Waku Mode, the checks in processQueue are rather useless as the
    # idea is to connect only to 1 node? Also refactor in that case.
    if node.protocolState(Waku).config.isLightNode:
      for peer in node.peers(Waku):
        peer.processQueue()

proc postMessage*(node: EthereumNode, pubKey = none[PublicKey](),
                  symKey = none[SymKey](), src = none[PrivateKey](),
                  ttl: uint32, topic: whisper_types.Topic, payload: seq[byte],
                  padding = none[seq[byte]](), powTime = 1'f,
                  powTarget = defaultMinPow,
                  targetPeer = none[NodeId]()): bool =
  ## Post a message on the message queue which will be processed at the
  ## next `messageInterval`.
  ##
  ## NOTE: This call allows a post without encryption. If encryption is
  ## mandatory it should be enforced a layer up
  let payload = encode(node.rng[], Payload(
    payload: payload, src: src, dst: pubKey, symKey: symKey, padding: padding))
  if payload.isSome():
    return node.postEncoded(ttl, topic, payload.get(), powTime, powTarget, targetPeer)
  else:
    error "Encoding of payload failed"
    return false

proc subscribeFilter*(node: EthereumNode, filter: Filter,
                      handler:FilterMsgHandler = nil): string =
  ## Initiate a filter for incoming/outgoing messages. Messages can be
  ## retrieved with the `getFilterMessages` call or with a provided
  ## `FilterMsgHandler`.
  ##
  ## NOTE: This call allows for a filter without decryption. If encryption is
  ## mandatory it should be enforced a layer up.
  return subscribeFilter(
    node.rng[], node.protocolState(Waku).filters, filter, handler)

proc unsubscribeFilter*(node: EthereumNode, filterId: string): bool =
  ## Remove a previously subscribed filter.
  var filter: Filter
  return node.protocolState(Waku).filters.take(filterId, filter)

proc getFilterMessages*(node: EthereumNode, filterId: string):
    seq[ReceivedMessage] {.raises: [KeyError, Defect].} =
  ## Get all the messages currently in the filter queue. This will reset the
  ## filter message queue.
  return node.protocolState(Waku).filters.getFilterMessages(filterId)

proc filtersToBloom*(node: EthereumNode): Bloom =
  ## Returns the bloom filter of all topics of all subscribed filters.
  return node.protocolState(Waku).filters.toBloom()

proc setPowRequirement*(node: EthereumNode, powReq: float64) {.async.} =
  ## Sets the PoW requirement for this node, will also send
  ## this new PoW requirement to all connected peers.
  ##
  ## Failures when sending messages to peers will not be reported.
  # NOTE: do we need a tolerance of old PoW for some time?
  node.protocolState(Waku).config.powRequirement = powReq
  var futures: seq[Future[void]] = @[]
  let list = StatusOptions(powRequirement: some(powReq))
  for peer in node.peers(Waku):
    futures.add(peer.statusOptions(list))

  # Exceptions from sendMsg will not be raised
  await allFutures(futures)

proc setBloomFilter*(node: EthereumNode, bloom: Bloom) {.async.} =
  ## Sets the bloom filter for this node, will also send
  ## this new bloom filter to all connected peers.
  ##
  ## Failures when sending messages to peers will not be reported.
  # NOTE: do we need a tolerance of old bloom filter for some time?
  node.protocolState(Waku).config.bloom = some(bloom)
  # reset topics
  node.protocolState(Waku).config.topics = none(seq[whisper_types.Topic])

  var futures: seq[Future[void]] = @[]
  let list = StatusOptions(bloomFilter: some(bloom))
  for peer in node.peers(Waku):
    futures.add(peer.statusOptions(list))

  # Exceptions from sendMsg will not be raised
  await allFutures(futures)

proc setTopicInterest*(node: EthereumNode, topics: seq[whisper_types.Topic]):
    Future[bool] {.async.} =
  if topics.len > topicInterestMax:
    return false

  node.protocolState(Waku).config.topics = some(topics)

  var futures: seq[Future[void]] = @[]
  let list = StatusOptions(topicInterest: some(topics))
  for peer in node.peers(Waku):
    futures.add(peer.statusOptions(list))

  # Exceptions from sendMsg will not be raised
  await allFutures(futures)

  return true

proc setMaxMessageSize*(node: EthereumNode, size: uint32): bool =
  ## Set the maximum allowed message size.
  ## Can not be set higher than ``defaultMaxMsgSize``.
  if size > defaultMaxMsgSize:
    warn "size > defaultMaxMsgSize"
    return false
  node.protocolState(Waku).config.maxMsgSize = size
  return true

proc setPeerTrusted*(node: EthereumNode, peerId: NodeId): bool =
  ## Set a connected peer as trusted.
  for peer in node.peers(Waku):
    if peer.remote.id == peerId:
      peer.state(Waku).trusted = true
      return true

proc setLightNode*(node: EthereumNode, isLightNode: bool) {.async.} =
  ## Set this node as a Waku light node.
  node.protocolState(Waku).config.isLightNode = isLightNode
# TODO: Add starting/stopping of `processQueue` loop depending on value of isLightNode.
  var futures: seq[Future[void]] = @[]
  let list = StatusOptions(lightNode: some(isLightNode))
  for peer in node.peers(Waku):
    futures.add(peer.statusOptions(list))

  # Exceptions from sendMsg will not be raised
  await allFutures(futures)

proc configureWaku*(node: EthereumNode, config: WakuConfig) =
  ## Apply a Waku configuration.
  ##
  ## NOTE: Should be run before connection is made with peers as some
  ## of the settings are only communicated at peer handshake.
  node.protocolState(Waku).config = config

proc registerP2PRequestHandler*(node: EthereumNode,
    customHandler: P2PRequestHandler) =
  node.protocolState(Waku).p2pRequestHandler = customHandler

proc registerEnvReceivedHandler*(node: EthereumNode,
                                 customHandler: EnvReceivedHandler) =
  node.protocolState(Waku).envReceivedHandler = customHandler

proc resetMessageQueue*(node: EthereumNode) =
  ## Full reset of the message queue.
  ##
  ## NOTE: Not something that should be run in normal circumstances.
  node.protocolState(Waku).queue[] = initQueue(defaultQueueCapacity)
