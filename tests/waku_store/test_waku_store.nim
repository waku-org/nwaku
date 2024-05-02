{.used.}

import std/options, testutils/unittests, chronos, chronicles, libp2p/crypto/crypto

import
  ../../../waku/[
    common/paging,
    node/peer_manager,
    waku_core,
    waku_core/message/digest,
    waku_store,
    waku_store/client,
    waku_store/common,
  ],
  ../testlib/[common, wakucore],
  ./store_utils

suite "Waku Store - query handler":
  asyncTest "history query handler should be called":
    info "AAAAA "
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    info "AAAAA "

    await allFutures(serverSwitch.start(), clientSwitch.start())
    info "AAAAA "

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
    info "AAAAA "
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    info "AAAAA "
    let kv = WakuMessageKeyValue(messageHash: hash, message: msg)
    info "AAAAA "

    var queryHandlerFut = newFuture[(StoreQueryRequest)]()
    info "AAAAA "

    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      var request = req
      info "AAAAA "
      request.requestId = "" # Must remove the id for equality
      queryHandlerFut.complete(request)
      return ok(StoreQueryResponse(messages: @[kv]))
    info "AAAAA "

    let
      server = await newTestWakuStore(serverSwitch, handler = queryhandler)
      client = newTestWakuStoreClient(clientSwitch)
    info "AAAAA "
    let req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic], paginationForward: PagingDirection.FORWARD
    )
    info "AAAAA "

    ## When
    let queryRes = await client.query(req, peer = serverPeerInfo)
    info "AAAAA "

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isOk()

    info "AAAAA "
    let request = queryHandlerFut.read()
    check:
      request == req
    info "AAAAA "
    let response = queryRes.tryGet()
    check:
      response.messages.len == 1
      response.messages == @[kv]
    info "AAAAA "
    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())
    info "AAAAA "

  asyncTest "history query handler should be called and return an error":
    ## Setup
    info "AAAAA "
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    info "AAAAA "
    await allFutures(serverSwitch.start(), clientSwitch.start())
    info "AAAAA "

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    var queryHandlerFut = newFuture[(StoreQueryRequest)]()
    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      var request = req
      request.requestId = "" # Must remove the id for equality
      queryHandlerFut.complete(request)
      return err(StoreError(kind: ErrorCode.BAD_REQUEST))
    info "AAAAA "

    let
      server = await newTestWakuStore(serverSwitch, handler = queryhandler)
      client = newTestWakuStoreClient(clientSwitch)
    info "AAAAA "

    let req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic], paginationForward: PagingDirection.FORWARD
    )
    info "AAAAA "

    ## When
    let queryRes = await client.query(req, peer = serverPeerInfo)
    info "AAAAA "

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isErr()
    info "AAAAA "

    let request = queryHandlerFut.read()
    check:
      request == req

    let error = queryRes.tryError()
    check:
      error.kind == ErrorCode.BAD_REQUEST

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())
    info "AAAAA "
