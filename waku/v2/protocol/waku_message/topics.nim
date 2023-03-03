## Waku topics definition and namespacing utils
##
## See 14/WAKU2-MESSAGE RFC: https://rfc.vac.dev/spec/14/
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/strutils,
  stew/results


## Topics

type
  PubsubTopic* = string
  ContentTopic* = string

const
  DefaultPubsubTopic* = PubsubTopic("/waku/2/default-waku/proto")
  DefaultContentTopic* = ContentTopic("/waku/2/default-content/proto")


## Namespacing

type
  NamespacedTopic* = object
    application*: string
    version*: string
    name*: string
    encoding*: string

type
  NamespacingErrorKind* {.pure.} = enum
    InvalidFormat

  NamespacingError* = object
    case kind*: NamespacingErrorKind
    of InvalidFormat:
      cause*: string

  NamespacingResult*[T] = Result[T, NamespacingError]


proc invalidFormat(T: type NamespacingError, cause = "invalid format"): T =
  NamespacingError(kind: NamespacingErrorKind.InvalidFormat, cause: cause)

proc `$`*(err: NamespacingError): string =
  case err.kind:
  of NamespacingErrorKind.InvalidFormat:
    return "invalid format: " & err.cause


proc parse*(T: type NamespacedTopic, topic: PubsubTopic|ContentTopic|string): NamespacingResult[NamespacedTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`

  if not topic.startsWith("/"):
    return err(NamespacingError.invalidFormat("topic must start with slash"))

  let parts = topic.split('/')

  # Check that we have an expected number of substrings
  if parts.len != 5:
    return err(NamespacingError.invalidFormat("invalid topic structure"))

  let namespaced = NamespacedTopic(
      application: parts[1],
      version: parts[2],
      name: parts[3],
      encoding: parts[4]
    )

  return ok(namespaced)

proc `$`*(namespacedTopic: NamespacedTopic): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/<application>/<version>/<topic-name>/<encoding>`
  var str = newString(0)

  str.add("/")
  str.add(namespacedTopic.application)
  str.add("/")
  str.add(namespacedTopic.version)
  str.add("/")
  str.add(namespacedTopic.name)
  str.add("/")
  str.add(namespacedTopic.encoding)

  return str
