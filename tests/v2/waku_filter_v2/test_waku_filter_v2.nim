{.used.}

import
  std/[options,sets,tables],
  testutils/unittests,
  chronos,
  chronicles
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/protocol/waku_filter_v2,
  ../../../waku/v2/protocol/waku_filter_v2/rpc,
  ../testlib/common,
  ../testlib/waku2

proc newTestWakuFilter(switch: Switch): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

suite "Waku Filter - handling subscribe requests":

  asyncTest "subscribe request":
    let
      switch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(switch)
      peerId = PeerId.random().get()
      filterSubscribeRequest = FilterSubscribeRequest(
        requestId: "1",
        filterSubscribeType: FilterSubscribeType.SUBSCRIBE,
        pubsubTopic: some("test-topic"),
        contentTopics: @["test-topic"]
      )

    let response = wakuFilter.handleSubscribeRequest(peerId, filterSubscribeRequest)

    check:
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions[peerId].len == 1
      response.requestId == filterSubscribeRequest.requestId
