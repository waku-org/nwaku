## Waku autosharding utils
##
## See 51/WAKU2-RELAY-SHARDING RFC: https://rfc.vac.dev/spec/51/#automatic-sharding

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  nimcrypto,
  std/math,
  std/sequtils,
  std/algorithm,
  stew/endians2

import
  ./content_topic,
  ./pubsub_topic

## Total number of shards in use for autosharding.
const TotalShards = 5

## Default shard cluster index.
const ClusterIndex = 0

func autoshard*(topic: NsContentTopic): NsPubsubTopic =
  var topics = toSeq(0..TotalShards)
    .mapIt(NsPubsubTopic.staticSharding(ClusterIndex, uint16(it)))
    .mapIt((topic: it, hash: sha256.digest($topic & $it)))
    .mapIt((topic: it.topic, hashValue: uint64.fromBytesBE(it.hash.data)))

  func hashOrder(x, y: tuple[topic: NsPubsubTopic, hashValue: uint64]): int =
    cmp(x.hashValue, y.hashValue)

  topics.sort(hashOrder)

  topics[0].topic

func weight(hashValue: uint64, weight: float64): float64 =
  -weight / math.ln(float64(hashValue) / float64(high(uint64)))
