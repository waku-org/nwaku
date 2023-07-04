when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, bitops, sequtils],
  stew/[endians2, results],
  stew/shims/net,
  chronicles,
  eth/keys,
  libp2p/[multiaddress, multicodec],
  libp2p/crypto/crypto
import
  ../../common/enr,
  ../waku_core

logScope:
  topics = "waku enr sharding"


const MaxShardIndex: uint16 = 1023

const
  ShardingIndicesListEnrField* = "rs"
  ShardingBitVectorEnrField* = "rsv"


type
  RelayShards* = object
    cluster: uint16
    indices: seq[uint16]


func cluster*(rs: RelayShards): uint16 =
  rs.cluster

func indices*(rs: RelayShards): seq[uint16] =
  rs.indices

func topics*(rs: RelayShards): seq[NsPubsubTopic] =
  rs.indices.mapIt(NsPubsubTopic.staticSharding(rs.cluster, it))


func init*(T: type RelayShards, cluster, index: uint16): T =
  if index > MaxShardIndex:
    raise newException(Defect, "invalid index")

  RelayShards(cluster: cluster, indices: @[index])

func init*(T: type RelayShards, cluster: uint16, indices: varargs[uint16]): T =
  if toSeq(indices).anyIt(it > MaxShardIndex):
    raise newException(Defect, "invalid index")

  let indicesSeq = deduplicate(@indices)
  if indices.len < 1:
    raise newException(Defect, "invalid index count")

  RelayShards(cluster: cluster, indices: indicesSeq)

func init*(T: type RelayShards, cluster: uint16, indices: seq[uint16]): T =
  if indices.anyIt(it > MaxShardIndex):
    raise newException(Defect, "invalid index")

  let indicesSeq = deduplicate(indices)
  if indices.len < 1:
    raise newException(Defect, "invalid index count")

  RelayShards(cluster: cluster, indices: indicesSeq)

func topicsToRelayShards*(topics: seq[string]): Result[Option[RelayShards], string] =
  if topics.len < 1:
    return ok(none(RelayShards))

  let parsedTopicsRes = topics.mapIt(NsPubsubTopic.parse(it))

  for res in parsedTopicsRes:
    if res.isErr():
      return err("failed to parse topic: " & $res.error)

  if parsedTopicsRes.allIt(it.get().kind == NsPubsubTopicKind.NamedSharding):
    return ok(none(RelayShards))

  if parsedTopicsRes.anyIt(it.get().kind == NsPubsubTopicKind.NamedSharding):
    return err("use named topics OR sharded ones not both.")

  if parsedTopicsRes.anyIt(it.get().cluster != parsedTopicsRes[0].get().cluster):
    return err("use sharded topics within the same cluster.")

  return ok(some(RelayShards.init(parsedTopicsRes[0].get().cluster, parsedTopicsRes.mapIt(it.get().shard))))

func contains*(rs: RelayShards, cluster, index: uint16): bool =
  rs.cluster == cluster and rs.indices.contains(index)

func contains*(rs: RelayShards, topic: NsPubsubTopic): bool =
  if topic.kind != NsPubsubTopicKind.StaticSharding:
    return false

  rs.contains(topic.cluster, topic.shard)

func contains*(rs: RelayShards, topic: PubsubTopic|string): bool =
  let parseRes = NsPubsubTopic.parse(topic)
  if parseRes.isErr():
    return false

  rs.contains(parseRes.value)


# ENR builder extension

func toIndicesList(rs: RelayShards): EnrResult[seq[byte]] =
  if rs.indices.len > high(uint8).int:
    return err("indices list too long")

  var res: seq[byte]
  res.add(rs.cluster.toBytesBE())

  res.add(rs.indices.len.uint8)
  for index in rs.indices:
    res.add(index.toBytesBE())

  ok(res)

func fromIndicesList(buf: seq[byte]): Result[RelayShards, string] =
  if buf.len < 3:
    return err("insufficient data: expected at least 3 bytes, got " & $buf.len & " bytes")

  let cluster = uint16.fromBytesBE(buf[0..1])
  let length = int(buf[2])

  if buf.len != 3 + 2 * length:
    return err("invalid data: `length` field is " & $length & " but " & $buf.len & " bytes were provided")

  var indices: seq[uint16]
  for i in 0..<length:
    indices.add(uint16.fromBytesBE(buf[3 + 2*i ..< 5 + 2*i]))

  ok(RelayShards(cluster: cluster, indices: indices))

func toBitVector(rs: RelayShards): seq[byte] =
  ## The value is comprised of a two-byte shard cluster index in network byte
  ## order concatenated with a 128-byte wide bit vector. The bit vector
  ## indicates which shards of the respective shard cluster the node is part
  ## of. The right-most bit in the bit vector represents shard 0, the left-most
  ## bit represents shard 1023.
  var res: seq[byte]
  res.add(rs.cluster.toBytesBE())

  var vec = newSeq[byte](128)
  for index in rs.indices:
    vec[index div 8].setBit(index mod 8)

  res.add(vec)

  res

func fromBitVector(buf: seq[byte]): EnrResult[RelayShards] =
  if buf.len != 130:
    return err("invalid data: expected 130 bytes")

  let cluster = uint16.fromBytesBE(buf[0..1])
  var indices: seq[uint16]

  for i in 0u16..<128u16:
    for j in 0u16..<8u16:
      if not buf[2 + i].testBit(j):
        continue

      indices.add(j + 8 * i)

  ok(RelayShards(cluster: cluster, indices: indices))


func withWakuRelayShardingIndicesList*(builder: var EnrBuilder, rs: RelayShards): EnrResult[void] =
  let value = ? rs.toIndicesList()
  builder.addFieldPair(ShardingIndicesListEnrField, value)
  ok()

func withWakuRelayShardingBitVector*(builder: var EnrBuilder, rs: RelayShards): EnrResult[void] =
  let value = rs.toBitVector()
  builder.addFieldPair(ShardingBitVectorEnrField, value)
  ok()

func withWakuRelaySharding*(builder: var EnrBuilder, rs: RelayShards): EnrResult[void] =
  if rs.indices.len >= 64:
    builder.withWakuRelayShardingBitVector(rs)
  else:
    builder.withWakuRelayShardingIndicesList(rs)

func withShardedTopics*(builder: var EnrBuilder,
                        topics: seq[string]):
                        Result[void, string] =
  let relayShardsRes = topicsToRelayShards(topics)
  let relayShardOp =
    if relayShardsRes.isErr():
      return err("building ENR with relay sharding failed: " &
                 $relayShardsRes.error)
    else: relayShardsRes.get()

  if relayShardOp.isNone():
    return ok()

  let res = builder.withWakuRelaySharding(relayShardOp.get())

  if res.isErr():
    return err($res.error)

  return ok()

# ENR record accessors (e.g., Record, TypedRecord, etc.)

proc relayShardingIndicesList*(record: TypedRecord): Option[RelayShards] =
  let field = record.tryGet(ShardingIndicesListEnrField, seq[byte])
  if field.isNone():
    return none(RelayShards)

  let indexList = fromIndicesList(field.get())
  if indexList.isErr():
    debug "invalid sharding indices list", error = indexList.error
    return none(RelayShards)

  some(indexList.value)

proc relayShardingBitVector*(record: TypedRecord): Option[RelayShards] =
  let field = record.tryGet(ShardingBitVectorEnrField, seq[byte])
  if field.isNone():
    return none(RelayShards)

  let bitVector = fromBitVector(field.get())
  if bitVector.isErr():
    debug "invalid sharding bit vector", error = bitVector.error
    return none(RelayShards)

  some(bitVector.value)

proc relaySharding*(record: TypedRecord): Option[RelayShards] =
  let indexList = record.relayShardingIndicesList()
  if indexList.isSome():
    return indexList

  record.relayShardingBitVector()


## Utils

proc containsShard*(r: Record, cluster, index: uint16): bool =
  if index > MaxShardIndex:
    return false

  let recordRes = r.toTyped()
  if recordRes.isErr():
    debug "invalid ENR record", error = recordRes.error
    return false

  let rs = recordRes.value.relaySharding()
  if rs.isNone():
    return false

  rs.get().contains(cluster, index)

proc containsShard*(r: Record, topic: NsPubsubTopic): bool =
  if topic.kind != NsPubsubTopicKind.StaticSharding:
    return false

  containsShard(r, topic.cluster, topic.shard)

func containsShard*(r: Record, topic: PubsubTopic|string): bool =
  let parseRes = NsPubsubTopic.parse(topic)
  if parseRes.isErr():
    debug "invalid static sharding topic", topic = topic, error = parseRes.error
    return false

  containsShard(r, parseRes.value)
