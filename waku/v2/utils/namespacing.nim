## Collection of utilities related to namespaced topics
## Implemented according to the specified Waku v2 Topic Usage Recommendations
## More at https://rfc.vac.dev/spec/23/

{.push raises: [Defect]}

import
  std/strutils,
  stew/results

type
  NamespacedTopic* = object
    application*: string
    version*: string
    topicName*: string
    encoding*: string
  
  NamespacingResult*[T] = Result[T, string]

proc fromString*(T: type NamespacedTopic, topic: string): NamespacingResult[NamespacedTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  
  let parts = topic.split('/')
  
  if parts.len != 5:
    # Check that we have an expected number of substrings
    return err("invalid topic format")

  if parts[0] != "":
    # Ensures that topic starts with a "/"
    return err("invalid topic format")
  
  ok(NamespacedTopic(application: parts[1],
                     version: parts[2],
                     topicName: parts[3],
                     encoding: parts[4]))

proc `$`*(namespacedTopic: NamespacedTopic): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/<application>/<version>/<topic-name>/<encoding>`
  
  var topicStr = newString(0)

  topicStr.add("/")
  topicStr.add(namespacedTopic.application)
  topicStr.add("/")
  topicStr.add(namespacedTopic.version)
  topicStr.add("/")
  topicStr.add(namespacedTopic.topicName)
  topicStr.add("/")
  topicStr.add(namespacedTopic.encoding)

  return topicStr
