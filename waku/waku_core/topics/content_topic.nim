## Waku content topics definition and namespacing utils
##
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  std/strutils,
  stew/results
import
  ./parsing

export parsing


## Content topic

type ContentTopic* = string

const DefaultContentTopic* = ContentTopic("/waku/2/default-content/proto")


## Namespaced content topic

type ShardingBias* = enum
  Unbiased = "unbiased"
  Lower20 = "lower20"
  Higher80 = "higher80"

type
  NsContentTopic* = object
    generation*: Option[int]
    bias*: ShardingBias
    application*: string
    version*: string
    name*: string
    encoding*: string

proc init*(T: type NsContentTopic, generation: Option[int], bias: ShardingBias,
  application: string, version: string, name: string, encoding: string): T =
  NsContentTopic(
    generation: generation,
    bias: bias,
    application: application,
    version: version,
    name: name,
    encoding: encoding
  )

# Serialization

proc `$`*(topic: NsContentTopic): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/<application>/<version>/<topic-name>/<encoding>`
  ## Autosharding adds 2 optional prefixes `/<gen#>/bias

  var formatted = ""

  if topic.generation.isSome():
    formatted = formatted & "/" & $topic.generation.get()

  if topic.bias != ShardingBias.Unbiased:
    formatted = formatted & "/" & $topic.bias

  formatted & "/" & topic.application & "/" & topic.version & "/" & topic.name & "/" & topic.encoding

# Deserialization

proc parse*(T: type NsContentTopic, topic: ContentTopic|string): ParsingResult[NsContentTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  ## Autosharding adds 2 optional prefixes `/<gen#>/bias

  if not topic.startsWith("/"):
    return err(ParsingError.invalidFormat("topic must start with slash"))

  let parts = topic[1..<topic.len].split("/")

  case parts.len:
    of 4:
      let app = parts[0]
      if app.len == 0:
        return err(ParsingError.missingPart("appplication"))

      let ver = parts[1]
      if ver.len == 0:
        return err(ParsingError.missingPart("version"))

      let name = parts[2]
      if name.len == 0:
        return err(ParsingError.missingPart("topic-name"))

      let enc = parts[3]
      if enc.len == 0:
        return err(ParsingError.missingPart("encoding"))

      return ok(NsContentTopic.init(none(int), Unbiased, app, ver, name, enc))
    of 6:
      if parts[0].len == 0:
        return err(ParsingError.missingPart("generation"))

      let gen = try:
        parseInt(parts[0])
      except ValueError:
        return err(ParsingError.invalidFormat("generation should be a numeric value"))

      if parts[1].len == 0:
        return err(ParsingError.missingPart("sharding-bias"))

      let bias = try:
        parseEnum[ShardingBias](parts[1])
      except ValueError:
        return err(ParsingError.invalidFormat("bias should be one of; unbiased, lower20 or higher80"))

      let app = parts[2]
      if app.len == 0:
        return err(ParsingError.missingPart("appplication"))

      let ver = parts[3]
      if ver.len == 0:
        return err(ParsingError.missingPart("version"))

      let name = parts[4]
      if name.len == 0:
        return err(ParsingError.missingPart("topic-name"))

      let enc = parts[5]
      if enc.len == 0:
        return err(ParsingError.missingPart("encoding"))

      return ok(NsContentTopic.init(some(gen), bias, app, ver, name, enc))
    else:
      return err(ParsingError.invalidFormat("invalid topic structure"))

# Content topic compatibility

converter toContentTopic*(topic: NsContentTopic): ContentTopic =
  $topic
