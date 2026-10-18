## Waku layer API — message publish primitives used by the messaging send
## pipeline.
##
## Unlike `relay.nim`/`lightpush.nim`, these preserve the rich
## `WakuLightPushResult` (status code + description) that the send processors
## branch on for their retry decisions, and expose relay/lightpush availability
## so the messaging layer never inspects `waku` directly.
{.push raises: [].}

import std/[tables, strutils]
import logos_delivery/kernel/[api/mix]
import results, chronos, libp2p/crypto/rng, libp2p_mix/pool

import logos_delivery/kernel/kernel
import
  logos_delivery/kernel/[
    base/topics/pubsub_topic,
    base/message,
    base/peers,
    base/codecs,
    rln/rln_api,
    rln/rln_plugin,
    api/lightpush,
    peer_manager/peer_manager,
    rln/markers,
    rln/rln_evm/group_manager,
    rln/rln_evm/conversion_utils,
    protocols/lightpush/common,
    protocols/lightpush/rpc,
    protocols/lightpush/callbacks,
    protocols/mix/protocol,
  ]
# WakuLightPushResult, PushMessageHandler, LightPushErrorCode (common) plus the
# LightPushStatusCode `$`/`==` the send processors branch on (rpc).
export common, rpc

proc hasRelay*(self: Kernel): bool =
  ## True if relay (gossipsub publishing) is mounted.
  return not self.protocols.relay.isNil()

proc hasLightpush*(self: Kernel): bool =
  ## True if a lightpush client is mounted.
  return not self.protocols.lightPushClient.isNil()

proc relayPushHandler*(self: Kernel): PushMessageHandler =
  ## Builds the relay publish handler used by the send pipeline. Caller
  ## ensures relay is mounted. The handler validates and republishes; the
  ## proof is attached by the messaging layer via `attachRlnProof`.
  return getRelayPushHandler(self.protocols.relay)

proc rlnEpochQuota*(
    self: Kernel, timestamp: uint64
): Future[Result[EpochQuota, RlnError]] {.async.} =
  ## The mounted RLN backend's budget snapshot for the epoch derived from
  ## `timestamp` (Unix seconds). An error without a backend that keeps one.
  return await epochQuota(self.protocols.rlnPlugin, timestamp)

proc attachRlnProof*(
    self: Kernel, message: WakuMessage
): Future[Result[WakuMessage, RlnError]] {.async.} =
  ## Returns `message` carrying an RLN proof. A message that already has one is
  ## returned untouched, so retrying a task neither redraws a nonce nor changes
  ## the bytes. Without RLN mounted the message passes through unproven. The
  ## error's kind tells the caller whether a retry can succeed.
  return await attachProof(self.protocols.rlnPlugin, message)

func needsRlnProof*(self: Kernel, message: WakuMessage): bool =
  ## True when `attachRlnProof` makes a proof for `message` and reserves an RLN
  ## message id.
  return self.protocols.rlnPlugin.needsProof(message)

func isRlnRejection*(error: ErrorStatus): bool =
  ## True when a publish failure means "the RLN proof was not accepted", so the
  ## message is worth retrying with a freshly generated proof rather than being
  ## failed outright.
  ##
  ## OUT_OF_RLN_PROOF is always RLN. INVALID_MESSAGE also covers non-RLN
  ## rejections (an oversized message, say), so it additionally has to carry the
  ## validator's error marker — this is the same gate the kernel lightpush path
  ## applies before scheduling a refresh.
  return
    error.code == LightPushErrorCode.OUT_OF_RLN_PROOF or (
      error.code == LightPushErrorCode.INVALID_MESSAGE and
      error.desc.get("").contains(RlnValidatorErrorMsg)
    )

proc onRlnProofRejected*(self: Kernel): bool =
  ## Tells the mounted RLN backend its proof was rejected. True when the
  ## backend will refresh what proofs are built against; see
  ## `notifyProofRejected`.
  return self.protocols.rlnPlugin.notifyProofRejected()

proc lightpushPeerAvailable*(self: Kernel, shard: PubsubTopic): bool =
  ## True if a lightpush service peer is available for `shard`.
  return self.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard)).isSome()

proc selectMixLightpushPeer*(self: Kernel, shard: PubsubTopic): Opt[RemotePeerInfo] =
  ## Selects a lightpush service peer for `shard` that mix can route to. With
  ## `exit_is_dest` the server is the last node of the sphinx path, so the mix
  ## pool must hold a `MixPubInfo` for it. The selection reads the service slot
  ## first, then draws one usable pool member uniformly.
  let peerStore = self.peerManager.switch.peerStore
  let pool = MixNodePool.new(peerStore)

  let slotted = self.peerManager.serviceSlots.getOrDefault(WakuLightPushCodec)
  if not slotted.isNil() and pool.get(slotted.peerId).isSome():
    return Opt.some(peerStore.getPeer(slotted.peerId))

  let shardInfo = RelayShard.parse(shard).valueOr:
    return Opt.none(RemotePeerInfo)

  var exits: seq[PeerId]
  for peerId in pool.peerIds():
    if not peerStore[ProtoBook][peerId].contains(WakuLightPushCodec):
      continue
    if not peerStore.hasShard(peerId, shardInfo.clusterId, shardInfo.shardId):
      continue
    if pool.get(peerId).isSome():
      exits.add(peerId)

  # The exit choice must not be predictable, so draw it from the node's CSPRNG,
  # as the mix delay strategy and the mix library's hop selection do. `pickOne`
  # is rejection-sampled and uniform.
  let exit = self.rng.pickOne(exits).valueOr:
    return Opt.none(RemotePeerInfo)
  return Opt.some(peerStore.getPeer(exit))

proc mixReady*(self: Kernel): bool =
  ## True when mix is mounted, mix can encode this node's own hop, and the pool
  ## has enough nodes for a path. `lightpushPublishToAny` selects the exit and
  ## reports SERVICE_NOT_AVAILABLE when it finds none.
  if self.protocols.mix.isNil():
    return false
  if not self.protocols.mix.selfHopUsable():
    return false
  return self.getMixNodePoolSize() >= MinMixPoolSize

proc mixMounted*(self: Kernel): bool =
  ## True when mix is mounted. A short pool or a missing exit can clear with
  ## time; a node without mix never sends over mix.
  return not self.protocols.mix.isNil()

proc mixSelfHopUsable*(self: Kernel): bool =
  ## True when mix is mounted and can encode this node's own hop. `mixReady`
  ## also checks this; the send path reads it alone to name the reason.
  return not self.protocols.mix.isNil() and self.protocols.mix.selfHopUsable()

proc lightpushPublishToAny*(
    self: Kernel, shard: PubsubTopic, message: WakuMessage, mixify: bool = false
): Future[WakuLightPushResult] {.async.} =
  ## Selects a lightpush service peer for `shard` and publishes `message`
  ## through the node's lightpush flow. With RLN mounted the flow proves
  ## `message` only if it carries no proof, so an already-proven task reuses its
  ## nonce. Returns SERVICE_NOT_AVAILABLE when no peer is available.
  let peerOpt =
    if mixify:
      self.selectMixLightpushPeer(shard)
    else:
      self.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard))
  let peer = peerOpt.valueOr:
    if mixify:
      return lightpushResultServiceUnavailable(
        "no mix-capable lightpush peer available for shard"
      )
    return lightpushResultServiceUnavailable("no lightpush peer available for shard")
  try:
    return await self.lightpushPublish(Opt.some(shard), message, Opt.some(peer), mixify)
  except CancelledError as exc:
    # The send service cancelled this attempt during its stop. Raise the cancel
    # again, so that `deliver` ends with the cancel and counts no failed attempt.
    raise exc
  except CatchableError as e:
    return lightpushResultInternalError(e.msg)
