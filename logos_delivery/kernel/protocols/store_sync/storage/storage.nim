import results

import
  logos_delivery/kernel/common/time,
  logos_delivery/kernel/topics/content_topic,
  logos_delivery/kernel/topics/pubsub_topic,
  logos_delivery/kernel/protocols/store_sync/common

type SyncStorage* = ref object of RootObj

method insert*(
    self: SyncStorage, element: SyncID, pubsubTopic: PubsubTopic, topic: ContentTopic
): Result[void, string] {.base, gcsafe, raises: [].} =
  return err("insert method not implemented for SyncStorage")

method batchInsert*(
    self: SyncStorage,
    elements: seq[SyncID],
    pubsubTopics: seq[PubsubTopic],
    contentTopics: seq[ContentTopic],
): Result[void, string] {.base, gcsafe, raises: [].} =
  return err("batchInsert method not implemented for SyncStorage")

method prune*(
    self: SyncStorage, timestamp: Timestamp
): int {.base, gcsafe, raises: [].} =
  -1

method computeFingerprint*(
    self: SyncStorage,
    bounds: Slice[SyncID],
    pubsubTopics: seq[PubsubTopic],
    contentTopics: seq[ContentTopic],
): Fingerprint {.base, gcsafe, raises: [].} =
  return FullFingerprint

method processPayload*(
    self: SyncStorage,
    input: RangesData,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
): RangesData {.base, gcsafe, raises: [].} =
  return RangesData(
    pubsubTopics: @["InsertPubsubTopicHere"],
    contentTopics: @["InsertContentTopicHere"],
    ranges: @[],
    fingerprints: @[FullFingerprint],
    itemSets: @[],
  )

method length*(self: SyncStorage): int {.base, gcsafe, raises: [].} =
  -1
