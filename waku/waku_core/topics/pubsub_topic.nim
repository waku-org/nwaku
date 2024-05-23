## Waku pub-sub topics definition and namespacing utils
##
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

{.push raises: [].}

import std/strutils, stew/base10, results
import ./parsing

export parsing

## Pub-sub topic

type PubsubTopic* = string

const DefaultPubsubTopic* = PubsubTopic("/waku/2/rs/0/0")

## Namespaced pub-sub topic

type NsPubsubTopic* = object
  clusterId*: uint16
  shardId*: uint16

proc staticSharding*(T: type NsPubsubTopic, clusterId, shardId: uint16): T =
  return NsPubsubTopic(clusterId: clusterId, shardId: shardId)

# Serialization

proc `$`*(topic: NsPubsubTopic): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/waku/2/<raw-topic>
  return "/waku/2/rs/" & $topic.clusterId & "/" & $topic.shardId

# Deserialization

const
  Waku2PubsubTopicPrefix = "/waku/2"
  StaticShardingPubsubTopicPrefix = Waku2PubsubTopicPrefix & "/rs"

proc parseStaticSharding*(
    T: type NsPubsubTopic, topic: PubsubTopic | string
): ParsingResult[NsPubsubTopic] =
  if not topic.startsWith(StaticShardingPubsubTopicPrefix):
    return err(
      ParsingError.invalidFormat("must start with " & StaticShardingPubsubTopicPrefix)
    )

  let parts = topic[11 ..< topic.len].split("/")
  if parts.len != 2:
    return err(ParsingError.invalidFormat("invalid topic structure"))

  let clusterPart = parts[0]
  if clusterPart.len == 0:
    return err(ParsingError.missingPart("cluster_id"))
  let clusterId =
    ?Base10.decode(uint16, clusterPart).mapErr(
      proc(err: auto): auto =
        ParsingError.invalidFormat($err)
    )

  let shardPart = parts[1]
  if shardPart.len == 0:
    return err(ParsingError.missingPart("shard_number"))
  let shardId =
    ?Base10.decode(uint16, shardPart).mapErr(
      proc(err: auto): auto =
        ParsingError.invalidFormat($err)
    )

  ok(NsPubsubTopic.staticSharding(clusterId, shardId))

proc parse*(
    T: type NsPubsubTopic, topic: PubsubTopic | string
): ParsingResult[NsPubsubTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  NsPubsubTopic.parseStaticSharding(topic)

# Pubsub topic compatibility

converter toPubsubTopic*(topic: NsPubsubTopic): PubsubTopic =
  $topic

proc `==`*[T: NsPubsubTopic](x, y: T): bool =
  if x.clusterId != y.clusterId:
    return false

  if x.shardId != y.shardId:
    return false

  return true
