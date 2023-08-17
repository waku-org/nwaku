{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto
import
  ../../../waku/node/peer_manager,
  ../../../waku/waku_core,
  ../../../waku/waku_store,
  ../../../waku/waku_store/client,
  ../testlib/common,
  ../testlib/wakucore

proc newTestWakuStore(switch: Switch, handler: HistoryQueryHandler): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuStore.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient(switch: Switch): WakuStoreClient =
  let peerManager = PeerManager.new(switch)
  WakuStoreClient.new(peerManager, rng)


suite "Waku Store - query handler":

  asyncTest "history query handler should be called":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let msg = fakeWakuMessage(contentTopic=DefaultContentTopic)

    var queryHandlerFut = newFuture[(HistoryQuery)]()

    let queryHandler = proc(req: HistoryQuery): Future[HistoryResult] {.async, gcsafe.} =
          queryHandlerFut.complete(req)
          return ok(HistoryResponse(messages: @[msg]))

    let
      server = await newTestWakuStore(serverSwitch, handler=queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], ascending: true)

    ## When
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isOk()

    let request = queryHandlerFut.read()
    check:
      request == req

    let response = queryRes.tryGet()
    check:
      response.messages.len == 1
      response.messages == @[msg]

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "history query handler should be called and return an error":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    var queryHandlerFut = newFuture[(HistoryQuery)]()
    let queryHandler = proc(req: HistoryQuery): Future[HistoryResult] {.async, gcsafe.} =
          queryHandlerFut.complete(req)
          return err(HistoryError(kind: HistoryErrorKind.BAD_REQUEST))

    let
      server = await newTestWakuStore(serverSwitch, handler=queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], ascending: true)

    ## When
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isErr()

    let request = queryHandlerFut.read()
    check:
      request == req

    let error = queryRes.tryError()
    check:
      error.kind == HistoryErrorKind.BAD_REQUEST

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())