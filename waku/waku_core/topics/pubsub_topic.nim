## Waku pub-sub topics definition and namespacing utils
##
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/strutils,
  stew/[results, base10]
import
  ./parsing

export parsing


## Pub-sub topic

type PubsubTopic* = string

const DefaultPubsubTopic* = PubsubTopic("/waku/2/default-waku/proto")


## Namespaced pub-sub topic

type
  NsPubsubTopicKind* {.pure.} = enum
    StaticSharding,
    NamedSharding

type
  NsPubsubTopic* = object
    case kind*: NsPubsubTopicKind
    of NsPubsubTopicKind.StaticSharding:
      cluster*: uint16
      shard*: uint16
    of NsPubsubTopicKind.NamedSharding:
      name*: string

proc staticSharding*(T: type NsPubsubTopic, cluster, shard: uint16): T =
  NsPubsubTopic(
    kind: NsPubsubTopicKind.StaticSharding,
    cluster: cluster,
    shard: shard
  )

proc named*(T: type NsPubsubTopic, name: string): T =
  NsPubsubTopic(
    kind: NsPubsubTopicKind.NamedSharding,
    name: name
  )


# Serialization

proc `$`*(topic: NsPubsubTopic): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/waku/2/<raw-topic>
  case topic.kind:
  of NsPubsubTopicKind.NamedSharding:
    "/waku/2/" & topic.name
  of NsPubsubTopicKind.StaticSharding:
    "/waku/2/rs/" & $topic.cluster & "/" & $topic.shard


# Deserialization

const
  Waku2PubsubTopicPrefix = "/waku/2"
  StaticShardingPubsubTopicPrefix = Waku2PubsubTopicPrefix & "/rs"


proc parseStaticSharding*(T: type NsPubsubTopic, topic: PubsubTopic|string): ParsingResult[NsPubsubTopic] =
  if not topic.startsWith(StaticShardingPubsubTopicPrefix):
    return err(ParsingError.invalidFormat("must start with " & StaticShardingPubsubTopicPrefix))

  let parts = topic[11..<topic.len].split("/")
  if parts.len != 2:
    return err(ParsingError.invalidFormat("invalid topic structure"))

  let clusterPart = parts[0]
  if clusterPart.len == 0:
    return err(ParsingError.missingPart("cluster_id"))
  let cluster = ?Base10.decode(uint16, clusterPart).mapErr(proc(err: auto): auto = ParsingError.invalidFormat($err))

  let shardPart = parts[1]
  if shardPart.len == 0:
    return err(ParsingError.missingPart("shard_number"))
  let shard = ?Base10.decode(uint16, shardPart).mapErr(proc(err: auto): auto = ParsingError.invalidFormat($err))

  ok(NsPubsubTopic.staticSharding(cluster, shard))

proc parseNamedSharding*(T: type NsPubsubTopic, topic: PubsubTopic|string): ParsingResult[NsPubsubTopic] =
  if not topic.startsWith(Waku2PubsubTopicPrefix):
    return err(ParsingError.invalidFormat("must start with " & Waku2PubsubTopicPrefix))

  let raw = topic[8..<topic.len]
  if raw.len == 0:
    return err(ParsingError.missingPart("topic-name"))

  ok(NsPubsubTopic.named(name=raw))

proc parse*(T: type NsPubsubTopic, topic: PubsubTopic|string): ParsingResult[NsPubsubTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  if topic.startsWith(StaticShardingPubsubTopicPrefix):
    NsPubsubTopic.parseStaticSharding(topic)
  else:
    NsPubsubTopic.parseNamedSharding(topic)


# Pubsub topic compatibility

converter toPubsubTopic*(topic: NsPubsubTopic): PubsubTopic =
  $topic

proc `==`*[T: NsPubsubTopic](x, y: T): bool =
  case y.kind
    of NsPubsubTopicKind.StaticSharding:
      if x.kind != NsPubsubTopicKind.StaticSharding:
        return false

      if x.cluster != y.cluster:
        return false

      if x.shard != y.shard:
        return false
    of NsPubsubTopicKind.NamedSharding:
      if x.kind != NsPubsubTopicKind.NamedSharding:
        return false

      if x.name != y.name:
        return false

  true
