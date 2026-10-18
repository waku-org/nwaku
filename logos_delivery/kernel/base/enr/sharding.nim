{.push raises: [].}

import
  std/[bitops, sequtils, net, tables],
  nimcrypto,
  stew/byteutils,
  stew/endians2,
  results,
  chronicles,
  eth/keys,
  libp2p/[multiaddress, multicodec],
  libp2p/crypto/crypto
import
  logos_delivery/kernel/[base/enr, base/topics/content_topic, base/topics/pubsub_topic]
logScope:
  topics = "waku enr sharding"

const MaxShardIndex*: uint16 = 1023

const
  ShardingIndicesListEnrField* = "rs"
  ShardingIndicesListMaxLength* = 64
  ShardingBitVectorEnrField* = "rsv"

type RelayShards* = object
  clusterId*: uint16
  shardIds*: seq[uint16]

func topics*(rs: RelayShards): seq[RelayShard] =
  rs.shardIds.mapIt(RelayShard(clusterId: rs.clusterId, shardId: it))

func init*(T: type RelayShards, clusterId, shardId: uint16): Result[T, string] =
  if shardId > MaxShardIndex:
    return err("invalid shard Id")

  ok(RelayShards(clusterId: clusterId, shardIds: @[shardId]))

func init*(
    T: type RelayShards, clusterId: uint16, shardIds: varargs[uint16]
): Result[T, string] =
  if toSeq(shardIds).anyIt(it > MaxShardIndex):
    return err("invalid shard")

  let indicesSeq = deduplicate(@shardIds)
  if shardIds.len < 1:
    return err("invalid shard count")

  ok(RelayShards(clusterId: clusterId, shardIds: indicesSeq))

func init*(
    T: type RelayShards, clusterId: uint16, shardIds: seq[uint16]
): Result[T, string] =
  if shardIds.anyIt(it > MaxShardIndex):
    return err("invalid shard")

  let indicesSeq = deduplicate(shardIds)
  if shardIds.len < 1:
    return err("invalid shard count")

  ok(RelayShards(clusterId: clusterId, shardIds: indicesSeq))

func topicsToRelayShards*(topics: seq[string]): Result[Opt[RelayShards], string] =
  if topics.len < 1:
    return ok(Opt.none(RelayShards))

  let parsedTopicsRes = topics.mapIt(RelayShard.parse(it))

  for res in parsedTopicsRes:
    res.isOkOr:
      return err("failed to parse topic: " & $error)

  if parsedTopicsRes.anyIt(it.get().clusterId != parsedTopicsRes[0].get().clusterId):
    return err("use shards with the same cluster Id.")

  let relayShard = ?RelayShards.init(
    parsedTopicsRes[0].get().clusterId, parsedTopicsRes.mapIt(it.get().shardId)
  )

  return ok(Opt.some(relayShard))

func contains*(rs: RelayShards, clusterId, shardId: uint16): bool =
  return rs.clusterId == clusterId and rs.shardIds.contains(shardId)

func contains*(rs: RelayShards, shard: RelayShard): bool =
  return rs.contains(shard.clusterId, shard.shardId)

func contains*(rs: RelayShards, topic: PubsubTopic): bool =
  let parseRes = RelayShard.parse(topic).valueOr:
    return false

  rs.contains(parseRes)

# ENR builder extension

func toIndicesList*(rs: RelayShards): EnrResult[seq[byte]] =
  if rs.shardIds.len > high(uint8).int:
    return err("shards list too long")

  var res: seq[byte]
  res.add(rs.clusterId.toBytesBE())

  res.add(rs.shardIds.len.uint8)
  for shardId in rs.shardIds:
    res.add(shardId.toBytesBE())

  ok(res)

func fromIndicesList*(buf: seq[byte]): Result[RelayShards, string] =
  if buf.len < 3:
    return
      err("insufficient data: expected at least 3 bytes, got " & $buf.len & " bytes")

  let clusterId = uint16.fromBytesBE(buf[0 .. 1])
  let length = int(buf[2])

  if buf.len != 3 + 2 * length:
    return err(
      "invalid data: `length` field is " & $length & " but " & $buf.len &
        " bytes were provided"
    )

  var shardIds: seq[uint16]
  for i in 0 ..< length:
    shardIds.add(uint16.fromBytesBE(buf[3 + 2 * i ..< 5 + 2 * i]))

  ok(RelayShards(clusterId: clusterId, shardIds: shardIds))

func toBitVector*(rs: RelayShards): seq[byte] =
  ## The value is comprised of a two-byte cluster id in network byte
  ## order concatenated with a 128-byte wide bit vector. The bit vector
  ## indicates which shard ids of the respective cluster id the node is part
  ## of. The right-most bit in the bit vector represents shard id 0, the left-most
  ## bit represents shard id 1023.
  var res: seq[byte]
  res.add(rs.clusterId.toBytesBE())

  var vec = newSeq[byte](128)
  for shardId in rs.shardIds:
    vec[shardId div 8].setBit(shardId mod 8)

  res.add(vec)

  res

func fromBitVector(buf: seq[byte]): EnrResult[RelayShards] =
  if buf.len != 130:
    return err("invalid data: expected 130 bytes")

  let clusterId = uint16.fromBytesBE(buf[0 .. 1])
  var shardIds: seq[uint16]

  for i in 0u16 ..< 128u16:
    for j in 0u16 ..< 8u16:
      if not buf[2 + i].testBit(j):
        continue

      shardIds.add(j + 8 * i)

  ok(RelayShards(clusterId: clusterId, shardIds: shardIds))

func withWakuRelayShardingIndicesList*(
    builder: var EnrBuilder, rs: RelayShards
): EnrResult[void] =
  let value = ?rs.toIndicesList()
  builder.addFieldPair(ShardingIndicesListEnrField, value)
  ok()

func withWakuRelayShardingBitVector*(
    builder: var EnrBuilder, rs: RelayShards
): EnrResult[void] =
  let value = rs.toBitVector()
  builder.addFieldPair(ShardingBitVectorEnrField, value)
  ok()

func withWakuRelaySharding*(builder: var EnrBuilder, rs: RelayShards): EnrResult[void] =
  if rs.shardIds.len >= ShardingIndicesListMaxLength:
    builder.withWakuRelayShardingBitVector(rs)
  else:
    builder.withWakuRelayShardingIndicesList(rs)

func withShardedTopics*(
    builder: var EnrBuilder, topics: seq[string]
): Result[void, string] =
  let relayShardOp = topicsToRelayShards(topics).valueOr:
    return err("building ENR with relay sharding failed: " & $error)

  let relayShard = relayShardOp.valueOr:
    return ok()

  builder.withWakuRelaySharding(relayShard).isOkOr:
    return err($error)

  return ok()

# ENR record accessors (e.g., Record, TypedRecord, etc.)

proc relayShardingIndicesList*(record: TypedRecord): Opt[RelayShards] =
  let field = record.tryGet(ShardingIndicesListEnrField, seq[byte]).valueOr:
    return Opt.none(RelayShards)

  let indexList = fromIndicesList(field).valueOr:
    info "invalid shards list", error = error
    return Opt.none(RelayShards)

  Opt.some(indexList)

proc relayShardingBitVector*(record: TypedRecord): Opt[RelayShards] =
  let field = record.tryGet(ShardingBitVectorEnrField, seq[byte]).valueOr:
    return Opt.none(RelayShards)

  let bitVector = fromBitVector(field).valueOr:
    info "invalid shards bit vector", error = error
    return Opt.none(RelayShards)

  Opt.some(bitVector)

proc relaySharding*(record: TypedRecord): Opt[RelayShards] =
  let indexList = record.relayShardingIndicesList().valueOr:
    return record.relayShardingBitVector()

  return Opt.some(indexList)

## Utils

proc containsShard*(r: Record, clusterId, shardId: uint16): bool =
  if shardId > MaxShardIndex:
    return false

  let record = r.toTyped().valueOr:
    trace "invalid ENR record", error = error
    return false

  let rs = record.relaySharding().valueOr:
    return false

  rs.contains(clusterId, shardId)

proc containsShard*(r: Record, shard: RelayShard): bool =
  return containsShard(r, shard.clusterId, shard.shardId)

proc containsShard*(r: Record, topic: PubsubTopic): bool =
  let parseRes = RelayShard.parse(topic).valueOr:
    info "invalid static sharding topic", topic = topic, error = error
    return false

  containsShard(r, parseRes)

proc isClusterMismatched*(record: Record, clusterId: uint16): bool =
  ## Check the ENR sharding info for matching cluster id
  if (let typedRecord = record.toTyped(); typedRecord.isOk()):
    if (let relayShard = typedRecord.get().relaySharding(); relayShard.isSome()):
      return relayShard.get().clusterId != clusterId

  return false

## Autosharding
##
## See 51/WAKU2-RELAY-SHARDING RFC: https://rfc.vac.dev/spec/51/#automatic-sharding

# TODO: this is autosharding, not just "sharding"
type Sharding* = object
  clusterId*: uint16
  # TODO: generations could be stored in a table here
  shards*: seq[uint16]
    ## Generation-zero shard ids: a content topic that hashes to index `i`
    ## lands on `shards[i]`.

proc init*(T: typedesc[Sharding], clusterId: uint16, shards: seq[uint16]): T =
  return Sharding(clusterId: clusterId, shards: shards)

proc init*(T: typedesc[Sharding], clusterId: uint16, shardCount: uint32): T =
  ## Auto-sharding over the shards `[0..shardCount-1]`.
  var shards = newSeqOfCap[uint16](shardCount)
  for i in 0'u32 ..< shardCount:
    shards.add(uint16(i))
  return Sharding.init(clusterId, shards)

proc getGenZeroShard*(s: Sharding, topic: NsContentTopic): RelayShard =
  let bytes = toBytes(topic.application) & toBytes(topic.version)

  let hash = sha256.digest(bytes)

  # We only use the last 64 bits of the hash as having more shards is unlikely.
  let hashValue = uint64.fromBytesBE(hash.data[24 .. 31])

  let index = hashValue mod uint64(s.shards.len)

  RelayShard(clusterId: s.clusterId, shardId: s.shards[index])

proc getShard*(s: Sharding, topic: NsContentTopic): Result[RelayShard, string] =
  ## Compute the (pubsub topic) shard to use for this content topic.

  if topic.generation.isNone():
    ## Implicit generation # is 0 for all content topic
    return ok(s.getGenZeroShard(topic))

  case topic.generation.get()
  of 0:
    return ok(s.getGenZeroShard(topic))
  else:
    return err("Generation > 0 are not supported yet")

proc getShard*(s: Sharding, topic: ContentTopic): Result[RelayShard, string] =
  let parsedTopic = NsContentTopic.parse(topic).valueOr:
    return err($error)

  let shard = ?s.getShard(parsedTopic)

  ok(shard)

proc getShardsFromContentTopics*(
    s: Sharding, contentTopics: ContentTopic | seq[ContentTopic]
): Result[Table[RelayShard, seq[NsContentTopic]], string] =
  let topics =
    when contentTopics is seq[ContentTopic]:
      contentTopics
    else:
      @[contentTopics]

  let nsContentTopics = NsContentTopic.parse(topics).valueOr:
    return err("Cannot parse content topic: " & $error)

  var topicMap = initTable[RelayShard, seq[NsContentTopic]]()
  for content in nsContentTopics:
    let shard = s.getShard(content).valueOr:
      return err("Cannot deduce shard from content topic: " & $error)

    if not topicMap.hasKey(shard):
      topicMap[shard] = @[]

    try:
      topicMap[shard].add(content)
    except CatchableError:
      return err(getCurrentExceptionMsg())

  ok(topicMap)

#type ShardsPriority = seq[tuple[topic: RelayShard, value: float64]]

#[ proc shardCount*(topic: NsContentTopic): Result[int, string] =
  ## Returns the total shard count from the content topic.
  let shardCount =
    if topic.generation.isNone():
      ## Implicit generation # is 0 for all content topic
      GenerationZeroShardsCount
    else:
      case topic.generation.get():
        of 0:
          GenerationZeroShardsCount
        else:
          return err("Generation > 0 are not supported yet")

  ok((shardCount)) ]#

#[ proc applyWeight(hashValue: uint64, weight: float64): float64 =
  (-weight) / math.ln(float64(hashValue) / float64(high(uint64))) ]#

#[ proc hashOrder*(x, y: (RelayShard, float64)): int =
    cmp(x[1], y[1]) ]#

#[ proc weightedShardList*(topic: NsContentTopic, shardCount: int, weightList: seq[float64]): Result[ShardsPriority, string] =
  ## Returns the ordered list of shards and their priority values.
  if weightList.len < shardCount:
    return err("Must provide weights for every shards")

  let shardsNWeights = zip(toSeq(0..shardCount), weightList)

  var list = newSeq[(RelayShard, float64)](shardCount)

  for (shard, weight) in shardsNWeights:
    let pubsub = RelayShard(clusterId: ClusterId, shardId: uint16(shard))

    let clusterBytes = toBytesBE(uint16(ClusterId))
    let shardBytes = toBytesBE(uint16(shard))
    let bytes = toBytes(topic.application) & toBytes(topic.version) & @clusterBytes & @shardBytes
    let hash = sha256.digest(bytes)
    let hashValue = uint64.fromBytesBE(hash.data)
    let value = applyWeight(hashValue, weight)

    list[shard] = (pubsub, value)

  list.sort(hashOrder)

  ok(list) ]#

#[ proc singleHighestWeigthShard*(topic: NsContentTopic): Result[RelayShard, string] =
  let count = ? shardCount(topic)

  let weights = repeat(1.0, count)

  let list = ? weightedShardList(topic, count, weights)

  let (pubsub, _) = list[list.len - 1]

  ok(pubsub) ]#
