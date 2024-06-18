import
  std/[strformat, sysrand, random, sequtils],
  system/ansi_c,
  chronicles,
  chronos,
  stew/byteutils,
  results,
  json_serialization as js
import
  waku/[
    common/logging,
    waku_node,
    node/peer_manager,
    waku_core,
    waku_lightpush/client,
    common/utils/parse_size_units,
  ],
  ./tester_config,
  ./tester_message

randomize()

type SizeRange* = tuple[min: uint64, max: uint64]

var RANDOM_PALYLOAD {.threadvar.}: seq[byte]
RANDOM_PALYLOAD = urandom(1024 * 1024)
  # 1MiB of random payload to be used to extend message

proc prepareMessage(
    sender: string,
    messageIndex, numMessages: uint32,
    startedAt: TimeStamp,
    prevMessageAt: var Timestamp,
    contentTopic: ContentTopic,
    size: SizeRange,
): (WakuMessage, uint64) =
  var renderSize = rand(size.min .. size.max)
  let current = getNowInNanosecondTime()
  let payload = ProtocolTesterMessage(
    sender: sender,
    index: messageIndex,
    count: numMessages,
    startedAt: startedAt,
    sinceStart: current - startedAt,
    sincePrev: current - prevMessageAt,
    size: renderSize,
  )

  prevMessageAt = current

  let text = js.Json.encode(payload)
  let contentPayload = toBytes(text & " \0")

  if renderSize < len(contentPayload).uint64:
    renderSize = len(contentPayload).uint64

  let finalPayload = concat(
    contentPayload, RANDOM_PALYLOAD[0 .. renderSize - len(contentPayload).uint64]
  )
  let message = WakuMessage(
    payload: finalPayload, # content of the message
    contentTopic: contentTopic, # content topic to publish to
    ephemeral: true, # tell store nodes to not store it
    timestamp: current, # current timestamp
  )

  return (message, renderSize)

var sentMessages {.threadvar.}: OrderedTable[uint32, tuple[hash: string, relayed: bool]]

proc publishMessages(
    wakuNode: WakuNode,
    lightpushPubsubTopic: PubsubTopic,
    lightpushContentTopic: ContentTopic,
    numMessages: uint32,
    messageSizeRange: SizeRange,
    delayMessages: Duration,
) {.async.} =
  let startedAt = getNowInNanosecondTime()
  var prevMessageAt = startedAt
  var failedToSendCount: uint32 = 0
  var renderMsgSize = messageSizeRange
  # sets some default of min max message size to avoid conflict with meaningful payload size
  renderMsgSize.min = max(1024.uint64, renderMsgSize.min) # do not use less than 1KB
  renderMsgSize.max = max(2048.uint64, renderMsgSize.max) # minimum of max is 2KB
  renderMsgSize.min = min(renderMsgSize.min, renderMsgSize.max)
  renderMsgSize.max = max(renderMsgSize.min, renderMsgSize.max)

  let selfPeerId = $wakuNode.switch.peerInfo.peerId

  var messagesSent: uint32 = 1
  while numMessages >= messagesSent:
    let (message, msgSize) = prepareMessage(
      selfPeerId, messagesSent, numMessages, startedAt, prevMessageAt,
      lightpushContentTopic, renderMsgSize,
    )
    let wlpRes = await wakuNode.lightpushPublish(some(lightpushPubsubTopic), message)

    let msgHash = computeMessageHash(lightpushPubsubTopic, message).to0xHex

    if wlpRes.isOk():
      sentMessages[messagesSent] = (hash: msgHash, relayed: true)
      notice "published message using lightpush",
        index = messagesSent,
        count = numMessages,
        size = msgSize,
        pubsubTopic = lightpushPubsubTopic,
        hash = msgHash
    else:
      sentMessages[messagesSent] = (hash: msgHash, relayed: false)
      error "failed to publish message using lightpush",
        err = wlpRes.error, hash = msgHash
      inc(failedToSendCount)

    await sleepAsync(delayMessages)
    inc(messagesSent)

  let report = catch:
    """*----------------------------------------*
|  Expected  |    Sent    |   Failed   |
|{numMessages:>11} |{messagesSent-failedToSendCount-1:>11} |{failedToSendCount:>11} |
*----------------------------------------*""".fmt()

  if report.isErr:
    echo "Error while printing statistics"
  else:
    echo report.get()

  echo "*--------------------------------------------------------------------------------------------------*"
  echo "|  Index   | Relayed | Hash                                                                        |"
  for (index, info) in sentMessages.pairs:
    echo fmt"|{index:>10}|{info.relayed:<9}| {info.hash}"
  echo "*--------------------------------------------------------------------------------------------------*"

  discard c_raise(ansi_c.SIGTERM)

proc setupAndPublish*(wakuNode: WakuNode, conf: LiteProtocolTesterConf) =
  if isNil(wakuNode.wakuLightpushClient):
    error "WakuFilterClient not initialized"
    return

  # give some time to receiver side to set up
  let waitTillStartTesting = conf.startPublishingAfter.seconds

  let parsedMinMsgSize = parseMsgSize(conf.minTestMessageSize).valueOr:
    error "failed to parse 'min-test-msg-size' param: ", error = error
    return

  let parsedMaxMsgSize = parseMsgSize(conf.maxTestMessageSize).valueOr:
    error "failed to parse 'max-test-msg-size' param: ", error = error
    return

  info "Sending test messages in", wait = waitTillStartTesting
  waitFor sleepAsync(waitTillStartTesting)

  info "Start sending messages to service node using lightpush"

  sentMessages.sort(system.cmp)
  # Start maintaining subscription
  asyncSpawn publishMessages(
    wakuNode,
    conf.pubsubTopics[0],
    conf.contentTopics[0],
    conf.numMessages,
    (min: parsedMinMsgSize, max: parsedMaxMsgSize),
    conf.delayMessages.milliseconds,
  )
