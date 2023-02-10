when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/byteutils
import
  # Waku v1 imports
  ../../waku/v1/protocol/waku_protocol,
  # Waku v2 imports
  libp2p/crypto/crypto,
  ../../waku/v2/utils/namespacing,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/peer_manager


const
  ContentTopicApplication = "waku"
  ContentTopicAppVersion = "1"


proc toV1Topic*(contentTopic: ContentTopic): waku_protocol.Topic {.raises: [LPError, ValueError]} =
  ## Extracts the 4-byte array v1 topic from a content topic
  ## with format `/waku/1/<v1-topic-bytes-as-hex>/rfc26`

  hexToByteArray(hexStr = NamespacedTopic.fromString(contentTopic).tryGet().topicName, N = 4)  # Byte array length

proc toV2ContentTopic*(v1Topic: waku_protocol.Topic): ContentTopic =
  ## Convert a 4-byte array v1 topic to a namespaced content topic
  ## with format `/waku/1/<v1-topic-bytes-as-hex>/rfc26`
  ##
  ## <v1-topic-bytes-as-hex> should be prefixed with `0x`
  var namespacedTopic = NamespacedTopic()

  namespacedTopic.application = ContentTopicApplication
  namespacedTopic.version = ContentTopicAppVersion
  namespacedTopic.topicName = "0x" & v1Topic.toHex()
  namespacedTopic.encoding = "rfc26"

  return ContentTopic($namespacedTopic)


proc isBridgeable*(msg: WakuMessage): bool =
  ## Determines if a Waku v2 msg is on a bridgeable content topic

  let ns = NamespacedTopic.fromString(msg.contentTopic)
  if ns.isOk():
    if ns.get().application == ContentTopicApplication and ns.get().version == ContentTopicAppVersion:
      return true

  return false
