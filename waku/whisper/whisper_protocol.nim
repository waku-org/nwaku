# nim-eth - Whisper
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Whisper
## *******
##
## Whisper is a gossip protocol that synchronizes a set of messages across nodes
## with attention given to sender and recipient anonymitiy. Messages are
## categorized by a topic and stay alive in the network based on a time-to-live
## measured in seconds. Spam prevention is based on proof-of-work, where large
## or long-lived messages must spend more work.
##
## Example usage
## ----------
## First an `EthereumNode` needs to be created, either with all capabilities set
## or with specifically the Whisper capability set.
## The latter can be done like this:
##
##   .. code-block::nim
##      var node = newEthereumNode(keypair, address, netId, nil,
##                                 addAllCapabilities = false)
##      node.addCapability Whisper
##
## Now calls such as ``postMessage`` and ``subscribeFilter`` can be done.
## However, they only make real sense after ``connectToNetwork`` was started. As
## else there will be no peers to send and receive messages from.

{.push raises: [Defect].}

import
  std/[options, tables, times],
  chronos, chronicles, metrics,
  eth/[keys, async_utils, p2p],
  ./whisper_types

export
  whisper_types

logScope:
  topics = "whisper"

const
  defaultQueueCapacity = 2048
  whisperVersion* = 6 ## Whisper version.
  whisperVersionStr* = $whisperVersion ## Whisper version.
  defaultMinPow* = 0.2'f64 ## The default minimum PoW requirement for this node.
  defaultMaxMsgSize* = 1024'u32 * 1024'u32 ## The current default and max
  ## message size. This can never be larger than the maximum RLPx message size.
  messageInterval* = chronos.milliseconds(300) ## Interval at which messages are
  ## send to peers, in ms.
  pruneInterval* = chronos.milliseconds(1000)  ## Interval at which message
  ## queue is pruned, in ms.

type
  WhisperConfig* = object
    powRequirement*: float64
    bloom*: Bloom
    isLightNode*: bool
    maxMsgSize*: uint32

  WhisperPeer = ref object
    initialized: bool # when successfully completed the handshake
    powRequirement*: float64
    bloom*: Bloom
    isLightNode*: bool
    trusted*: bool
    received: HashSet[Hash]

  WhisperNetwork = ref object
    queue*: ref Queue
    filters*: Filters
    config*: WhisperConfig

proc allowed*(msg: Message, config: WhisperConfig): bool =
  # Check max msg size, already happens in RLPx but there is a specific shh
  # max msg size which should always be < RLPx max msg size
  if msg.size > config.maxMsgSize:
    envelopes_dropped.inc(labelValues = ["too_large"])
    warn "Message size too large", size = msg.size
    return false

  if msg.pow < config.powRequirement:
    envelopes_dropped.inc(labelValues = ["low_pow"])
    warn "Message PoW too low", pow = msg.pow, minPow = config.powRequirement
    return false

  if not bloomFilterMatch(config.bloom, msg.bloom):
    envelopes_dropped.inc(labelValues = ["bloom_filter_mismatch"])
    warn "Message does not match node bloom filter"
    return false

  return true

proc run(peer: Peer) {.gcsafe, async, raises: [Defect].}
proc run(node: EthereumNode, network: WhisperNetwork)
  {.gcsafe, async, raises: [Defect].}

proc initProtocolState*(network: WhisperNetwork, node: EthereumNode) {.gcsafe.} =
  new(network.queue)
  network.queue[] = initQueue(defaultQueueCapacity)
  network.filters = initTable[string, Filter]()
  network.config.bloom = fullBloom()
  network.config.powRequirement = defaultMinPow
  network.config.isLightNode = false
  network.config.maxMsgSize = defaultMaxMsgSize
  asyncSpawn node.run(network)

p2pProtocol Whisper(version = whisperVersion,
                    rlpxName = "shh",
                    peerState = WhisperPeer,
                    networkState = WhisperNetwork):

  onPeerConnected do (peer: Peer):
    trace "onPeerConnected Whisper"
    let
      whisperNet = peer.networkState
      whisperPeer = peer.state

    let m = await peer.status(whisperVersion,
                              cast[uint64](whisperNet.config.powRequirement),
                              @(whisperNet.config.bloom),
                              whisperNet.config.isLightNode,
                              timeout = chronos.milliseconds(5000))

    if m.protocolVersion == whisperVersion:
      debug "Whisper peer", peer, whisperVersion
    else:
      raise newException(UselessPeerError, "Incompatible Whisper version")

    whisperPeer.powRequirement = cast[float64](m.powConverted)

    if m.bloom.len > 0:
      if m.bloom.len != bloomSize:
        raise newException(UselessPeerError, "Bloomfilter size mismatch")
      else:
        whisperPeer.bloom.bytesCopy(m.bloom)
    else:
      # If no bloom filter is send we allow all
      whisperPeer.bloom = fullBloom()

    whisperPeer.isLightNode = m.isLightNode
    if whisperPeer.isLightNode and whisperNet.config.isLightNode:
      # No sense in connecting two light nodes so we disconnect
      raise newException(UselessPeerError, "Two light nodes connected")

    whisperPeer.received.init()
    whisperPeer.trusted = false
    whisperPeer.initialized = true

    if not whisperNet.config.isLightNode:
      asyncSpawn peer.run()

    debug "Whisper peer initialized", peer

  handshake:
    proc status(peer: Peer,
                protocolVersion: uint,
                powConverted: uint64,
                bloom: seq[byte],
                isLightNode: bool)

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

  proc powRequirement(peer: Peer, value: uint64) =
    if not peer.state.initialized:
      warn "Handshake not completed yet, discarding powRequirement"
      return

    peer.state.powRequirement = cast[float64](value)

  proc bloomFilterExchange(peer: Peer, bloom: openArray[byte]) =
    if not peer.state.initialized:
      warn "Handshake not completed yet, discarding bloomFilterExchange"
      return

    if bloom.len == bloomSize:
      peer.state.bloom.bytesCopy(bloom)

  nextID 126

  proc p2pRequest(peer: Peer, envelope: Envelope) =
    # TODO: here we would have to allow to insert some specific implementation
    # such as e.g. Whisper Mail Server
    discard

  proc p2pMessage(peer: Peer, envelope: Envelope) =
    if peer.state.trusted:
      # when trusted we can bypass any checks on envelope
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

  proc p2pRequestComplete(peer: Peer) = discard

# 'Runner' calls ---------------------------------------------------------------

proc processQueue(peer: Peer) =
  # Send to peer all valid and previously not send envelopes in the queue.
  var
    envelopes: seq[Envelope] = @[]
    whisperPeer = peer.state(Whisper)
    whisperNet = peer.networkState(Whisper)

  for message in whisperNet.queue.items:
    if whisperPeer.received.contains(message.hash):
      # trace "message was already send to peer", hash = $message.hash, peer
      continue

    if message.pow < whisperPeer.powRequirement:
      trace "Message PoW too low for peer", pow = message.pow,
                                            powReq = whisperPeer.powRequirement
      continue

    if not bloomFilterMatch(whisperPeer.bloom, message.bloom):
      trace "Message does not match peer bloom filter"
      continue

    trace "Adding envelope"
    envelopes.add(message.env)
    whisperPeer.received.incl(message.hash)

  if envelopes.len() > 0:
    trace "Sending envelopes", amount=envelopes.len
    # Ignore failure of sending messages, this could occur when the connection
    # gets dropped
    traceAsyncErrors peer.messages(envelopes)

proc run(peer: Peer) {.async.} =
  while peer.connectionState notin {Disconnecting, Disconnected}:
    peer.processQueue()
    await sleepAsync(messageInterval)

proc pruneReceived(node: EthereumNode) =
  if node.peerPool != nil: # XXX: a bit dirty to need to check for this here ...
    var whisperNet = node.protocolState(Whisper)

    for peer in node.protocolPeers(Whisper):
      if not peer.initialized:
        continue

      # NOTE: Perhaps alter the queue prune call to keep track of a HashSet
      # of pruned messages (as these should be smaller), and diff this with
      # the received sets.
      peer.received = intersection(peer.received, whisperNet.queue.itemHashes)

proc run(node: EthereumNode, network: WhisperNetwork) {.async.} =
  while true:
    # prune message queue every second
    # TTL unit is in seconds, so this should be sufficient?
    network.queue[].prune()
    # pruning the received sets is not necessary for correct workings
    # but simply from keeping the sets growing indefinitely
    node.pruneReceived()
    await sleepAsync(pruneInterval)

# Private EthereumNode calls ---------------------------------------------------

proc sendP2PMessage(node: EthereumNode, peerId: NodeId, env: Envelope): bool =
  for peer in node.peers(Whisper):
    if peer.remote.id == peerId:
      let f = peer.p2pMessage(env)
      # Can't make p2pMessage not raise so this is the "best" option I can think
      # of instead of using asyncSpawn and still keeping the call not async.
      f.callback = proc(data: pointer) {.gcsafe, raises: [Defect].} =
        if f.failed:
          warn "P2PMessage send failed", msg = f.readError.msg

      return true

proc queueMessage(node: EthereumNode, msg: Message): bool =

  var whisperNet = node.protocolState(Whisper)
  # We have to do the same checks here as in the messages proc not to leak
  # any information that the message originates from this node.
  if not msg.allowed(whisperNet.config):
    return false

  trace "Adding message to queue", hash = $msg.hash
  if whisperNet.queue[].add(msg):
    # Also notify our own filters of the message we are sending,
    # e.g. msg from local Dapp to Dapp
    whisperNet.filters.notify(msg)

  return true

# Public EthereumNode calls ----------------------------------------------------

proc postMessage*(node: EthereumNode, pubKey = none[PublicKey](),
                  symKey = none[SymKey](), src = none[PrivateKey](),
                  ttl: uint32, topic: Topic, payload: seq[byte],
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
    var env = Envelope(expiry:epochTime().uint32 + ttl,
                       ttl: ttl, topic: topic, data: payload.get(), nonce: 0)

    # Allow lightnode to post only direct p2p messages
    if targetPeer.isSome():
      return node.sendP2PMessage(targetPeer.get(), env)
    elif not node.protocolState(Whisper).config.isLightNode:
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

      return node.queueMessage(msg)
    else:
      warn "Light node not allowed to post messages"
      return false
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
    node.rng[], node.protocolState(Whisper).filters, filter, handler)

proc unsubscribeFilter*(node: EthereumNode, filterId: string): bool =
  ## Remove a previously subscribed filter.
  var filter: Filter
  return node.protocolState(Whisper).filters.take(filterId, filter)

proc getFilterMessages*(node: EthereumNode, filterId: string):
    seq[ReceivedMessage] {.raises: [KeyError, Defect].} =
  ## Get all the messages currently in the filter queue. This will reset the
  ## filter message queue.
  return node.protocolState(Whisper).filters.getFilterMessages(filterId)

proc filtersToBloom*(node: EthereumNode): Bloom =
  ## Returns the bloom filter of all topics of all subscribed filters.
  return node.protocolState(Whisper).filters.toBloom()

proc setPowRequirement*(node: EthereumNode, powReq: float64) {.async.} =
  ## Sets the PoW requirement for this node, will also send
  ## this new PoW requirement to all connected peers.
  ##
  ## Failures when sending messages to peers will not be reported.
  # NOTE: do we need a tolerance of old PoW for some time?
  node.protocolState(Whisper).config.powRequirement = powReq
  var futures: seq[Future[void]] = @[]
  for peer in node.peers(Whisper):
    futures.add(peer.powRequirement(cast[uint64](powReq)))

  # Exceptions from sendMsg will not be raised
  await allFutures(futures)

proc setBloomFilter*(node: EthereumNode, bloom: Bloom) {.async.} =
  ## Sets the bloom filter for this node, will also send
  ## this new bloom filter to all connected peers.
  ##
  ## Failures when sending messages to peers will not be reported.
  # NOTE: do we need a tolerance of old bloom filter for some time?
  node.protocolState(Whisper).config.bloom = bloom
  var futures: seq[Future[void]] = @[]
  for peer in node.peers(Whisper):
    futures.add(peer.bloomFilterExchange(@bloom))

  # Exceptions from sendMsg will not be raised
  await allFutures(futures)

proc setMaxMessageSize*(node: EthereumNode, size: uint32): bool =
  ## Set the maximum allowed message size.
  ## Can not be set higher than ``defaultMaxMsgSize``.
  if size > defaultMaxMsgSize:
    warn "size > defaultMaxMsgSize"
    return false
  node.protocolState(Whisper).config.maxMsgSize = size
  return true

proc setPeerTrusted*(node: EthereumNode, peerId: NodeId): bool =
  ## Set a connected peer as trusted.
  for peer in node.peers(Whisper):
    if peer.remote.id == peerId:
      peer.state(Whisper).trusted = true
      return true

proc setLightNode*(node: EthereumNode, isLightNode: bool) =
  ## Set this node as a Whisper light node.
  ##
  ## NOTE: Should be run before connection is made with peers as this
  ## setting is only communicated at peer handshake.
  node.protocolState(Whisper).config.isLightNode = isLightNode

proc configureWhisper*(node: EthereumNode, config: WhisperConfig) =
  ## Apply a Whisper configuration.
  ##
  ## NOTE: Should be run before connection is made with peers as some
  ## of the settings are only communicated at peer handshake.
  node.protocolState(Whisper).config = config

proc resetMessageQueue*(node: EthereumNode) =
  ## Full reset of the message queue.
  ##
  ## NOTE: Not something that should be run in normal circumstances.
  node.protocolState(Whisper).queue[] = initQueue(defaultQueueCapacity)
