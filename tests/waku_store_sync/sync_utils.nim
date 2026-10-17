import std/random, chronos, metrics

import
  logos_delivery/kernel/[
    node/peer_manager/peer_manager,
    topics/content_topic,
    topics/pubsub_topic,
    common/time,
    protocols/message,
    protocols/store_sync/common,
    protocols/store_sync/reconciliation,
    protocols/store_sync/transfer,
    protocols/store_sync/protocols_metrics,
  ],
  ../testlib/wakucore

randomize()

type TransferDirection* {.pure.} = enum
  Sent
  Received

proc transferCount*(direction: TransferDirection): float64 =
  let label =
    case direction
    of TransferDirection.Sent: Sending
    of TransferDirection.Received: Receiving
  try:
    return logos_delivery_total_transfer_messages_exchanged.valueByName(
      "logos_delivery_total_transfer_messages_exchanged_total", [label]
    )
  except ValueError:
    return 0.0

proc randomHash*(rng: var Rand): WakuMessageHash =
  var hash = EmptyWakuMessageHash

  for i in 0 ..< hash.len:
    hash[i] = rng.rand(uint8)

  return hash

proc newTestWakuRecon*(
    switch: Switch,
    pubsubTopics: seq[PubsubTopic] = @[],
    contentTopics: seq[ContentTopic] = @[],
    syncRange: timer.Duration = DefaultSyncRange,
    idsRx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    wantsTx: AsyncQueue[PeerId],
    needsTx: AsyncQueue[(PeerId, WakuMessageHash)],
    relayJitter: timer.Duration = 0.seconds,
    syncInterval: timer.Duration = DefaultSyncInterval,
    clock: proc(): Timestamp {.gcsafe, raises: [].} = getNowInNanosecondTime,
): Future[SyncReconciliation] {.async.} =
  let peerManager = PeerManager.new(switch)

  let res = await SyncReconciliation.new(
    pubsubTopics = pubsubTopics,
    contentTopics = contentTopics,
    peerManager = peerManager,
    wakuArchive = nil,
    syncRange = syncRange,
    syncInterval = syncInterval,
    relayJitter = relayJitter,
    idsRx = idsRx,
    localWantsTx = wantsTx,
    remoteNeedsTx = needsTx,
    clock = clock,
  )

  let proto = res.get()

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuTransfer*(
    switch: Switch,
    idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    wantsRx: AsyncQueue[PeerId],
    needsRx: AsyncQueue[(PeerId, WakuMessageHash)],
): Future[SyncTransfer] {.async.} =
  let peerManager = PeerManager.new(switch)

  let proto = SyncTransfer.new(
    peerManager = peerManager,
    wakuArchive = nil,
    idsTx = idsTx,
    localWantsRx = wantsRx,
    remoteNeedsRx = needsRx,
    maxMessageSize = int(DefaultMaxWakuMessageSize),
  )

  await proto.start()
  switch.mount(proto)

  return proto
