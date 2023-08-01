when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/[byteutils, results],
  libp2p/crypto/crypto
import
  ../../waku/v1/protocol/waku_protocol,
  ../../waku/v2/waku_core


const
  ContentTopicApplication = "waku"
  ContentTopicAppVersion = "1"


proc toV1Topic*(contentTopic: ContentTopic): waku_protocol.Topic {.raises: [ValueError]} =
  ## Extracts the 4-byte array v1 topic from a content topic
  ## with format `/waku/1/<v1-topic-bytes-as-hex>/rfc26`

  let ns = NsContentTopic.parse(contentTopic)
  if ns.isErr():
    let err = ns.tryError()
    raise newException(ValueError, $err)

  let name = ns.value.name
  hexToByteArray(hexStr=name, N=4)  # Byte array length

proc toV2ContentTopic*(v1Topic: waku_protocol.Topic): ContentTopic =
  ## Convert a 4-byte array v1 topic to a namespaced content topic
  ## with format `/waku/1/<v1-topic-bytes-as-hex>/rfc26`
  ##
  ## <v1-topic-bytes-as-hex> should be prefixed with `0x`
  var namespacedTopic = NsContentTopic()

  namespacedTopic.generation = none(int)
  namespacedTopic.bias = Unbiased
  namespacedTopic.application = ContentTopicApplication
  namespacedTopic.version = ContentTopicAppVersion
  namespacedTopic.name = v1Topic.to0xHex()
  namespacedTopic.encoding = "rfc26"

  return ContentTopic($namespacedTopic)


proc isBridgeable*(msg: WakuMessage): bool =
  ## Determines if a Waku v2 msg is on a bridgeable content topic
  let ns = NsContentTopic.parse(msg.contentTopic)
  if ns.isErr():
    return false

  return ns.value.application == ContentTopicApplication and ns.value.version == ContentTopicAppVersion
