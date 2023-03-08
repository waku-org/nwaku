{.used.}

import
  std/[options,sets,strutils,tables],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/peerstore
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/protocol/waku_filter_v2,
  ../../../waku/v2/protocol/waku_filter_v2/client,
  ../../../waku/v2/protocol/waku_filter_v2/rpc,
  ../../../waku/v2/protocol/waku_message,
  ../testlib/common,
  ../testlib/waku2

proc newTestWakuFilter(switch: Switch): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuFilterClient(switch: Switch, messagePushHandler: MessagePushHandler): Future[WakuFilterClient] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilterClient.new(messagePushHandler, peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

proc generateRequestId(rng: ref HmacDrbgContext): string =
  var bytes: array[10, byte]
  hmacDrbgGenerate(rng[], bytes)
  return toHex(bytes)

proc createRequest(filterSubscribeType: FilterSubscribeType, pubsubTopic = none(PubsubTopic), contentTopics = newSeq[ContentTopic]()): FilterSubscribeRequest =
  let requestId = generateRequestId(rng)

  return FilterSubscribeRequest(
    requestId: requestId,
    filterSubscribeType: filterSubscribeType,
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics
  )

suite "Waku Filter - end to end":

  asyncTest "simple subscribe and unsubscribe request":
    # Given
    var messagePushHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
      echo pubsubTopic, message

    let
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, messagePushHandler)
      clientPeerId = clientSwitch.peerInfo.peerId
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic]
      )
      filterUnsubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest.pubsubTopic,
        contentTopics = filterSubscribeRequest.contentTopics
      )

    # When
    await allFutures(serverSwitch.start(), clientSwitch.start())
    discard await clientSwitch.dial(serverSwitch.peerInfo.peerId, serverSwitch.peerInfo.listenAddrs, WakuFilterSubscribeCodec)
    let response = wakuFilter.handleSubscribeRequest(clientPeerId, filterSubscribeRequest)

    # Then
    check:
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    await wakuFilter.handleMessage(DefaultPubsubTopic, fakeWakuMessage())

    # Teardown
    await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())
