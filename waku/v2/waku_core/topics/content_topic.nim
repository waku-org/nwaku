## Waku content topics definition and namespacing utils
##
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/strutils,
  stew/results
import
  ./parsing

export parsing


## Content topic

type ContentTopic* = string

const DefaultContentTopic* = ContentTopic("/waku/2/default-content/proto")


## Namespaced content topic

type
  NsContentTopic* = object
    generation*: string
    bias*: string
    application*: string
    version*: string
    name*: string
    encoding*: string

proc init*(T: type NsContentTopic, generation, bias, application, version, name, encoding: string): T =
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
  ## Autosharding adds 2 prefix `/<gen#>/<bias-name>
  "/" & topic.generation & "/" & topic.bias & "/" & topic.application & "/" & topic.version & "/" & topic.name & "/" & topic.encoding


# Deserialization

proc parse*(T: type NsContentTopic, topic: ContentTopic|string): ParsingResult[NsContentTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  ## Autosharding adds 2 prefix `/<gen#>/<bias-name>

  if not topic.startsWith("/"):
    return err(ParsingError.invalidFormat("topic must start with slash"))

  let parts = topic[1..<topic.len].split("/")
  if parts.len != 6:
    return err(ParsingError.invalidFormat("invalid topic structure"))

  let gen = parts[0]
  if gen.len == 0:
    return err(ParsingError.missingPart("generation"))

  let bias = parts[1]
  if bias.len == 0:
    return err(ParsingError.missingPart("sharding-bias"))

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


  ok(NsContentTopic.init(gen, bias, app, ver, name, enc))


# Content topic compatibility

converter toContentTopic*(topic: NsContentTopic): ContentTopic =
  $topic
