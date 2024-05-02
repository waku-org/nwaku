{.used.}

import
  std/sequtils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub
import
  ../../../waku/common/paging,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../../../waku/waku_core/subscription,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/sqlite_driver,
  ../../../waku/waku_filter_v2,
  ../../../waku/waku_filter_v2/client,
  ../../../waku/waku_store,
  ../../../waku/waku_node,
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/wakucore,
  ../testlib/wakunode

procSuite "WakuNode - Store":
  ## Fixtures
  let timeOrigin = now()
  info "AAAAA "
  let msgListA =
    @[
      fakeWakuMessage(@[byte 00], ts = ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 01], ts = ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 02], ts = ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 03], ts = ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 04], ts = ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 05], ts = ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 06], ts = ts(60, timeOrigin)),
      fakeWakuMessage(@[byte 07], ts = ts(70, timeOrigin)),
      fakeWakuMessage(@[byte 08], ts = ts(80, timeOrigin)),
      fakeWakuMessage(@[byte 09], ts = ts(90, timeOrigin)),
    ]
  info "AAAAA "

  let hashes = msgListA.mapIt(computeMessageHash(DefaultPubsubTopic, it))
  info "AAAAA "

  let kvs =
    zip(hashes, msgListA).mapIt(WakuMessageKeyValue(messageHash: it[0], message: it[1]))
  info "AAAAA "

  let archiveA = block:
    info "AAAAA "
    let driver = newSqliteArchiveDriver()
    info "AAAAA "

    for kv in kvs:
      info "AAAAA "
      let msg_digest = computeDigest(kv.message)
      info "AAAAA "
      require (
        waitFor driver.put(
          DefaultPubsubTopic, message, msg_digest, kv.messageHash, message.timestamp
        )
      ).isOk()

    driver
  info "AAAAA "

  test "Store protocol returns expected messages":
    info "AAAAA "
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start())
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore()
    info "AAAAA "

    client.mountStoreClient()
    info "AAAAA "

    ## Given
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    ## When
    let queryRes = waitFor client.query(req, peer = serverPeer)
    info "AAAAA "

    ## Then
    check queryRes.isOk()
    info "AAAAA "

    let response = queryRes.get()
    info "AAAAA "
    check:
      response.messages == kvs
    info "AAAAA "

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())
    info "AAAAA "

  test "Store node history response - forward pagination":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start())
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(archiveA)
    info "AAAAA "
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore()
    info "AAAAA "

    client.mountStoreClient()
    info "AAAAA "

    ## Given
    let req = StoreQueryRequest(
      includeData: true,
      contentTopics: @[DefaultContentTopic],
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: some(uint64(7)),
    )
    info "AAAAA "
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    ## When
    var nextReq = req # copy
    info "AAAAA "

    var pages = newSeq[seq[WakuMessageKeyValue]](2)
    info "AAAAA "
    var cursors = newSeq[Option[WakuMessageHash]](2)
    info "AAAAA "

    for i in 0 ..< 2:
      info "AAAAA "
      let res = waitFor client.query(nextReq, peer = serverPeer)
      info "AAAAA "
      require res.isOk()
      info "AAAAA "

      # Keep query response content
      let response = res.get()
      info "AAAAA "

      pages[i] = response.messages
      cursors[i] = response.paginationCursor
      info "AAAAA "
      # Set/update the request cursor
      nextReq.paginationCursor = cursors[i]
      info "AAAAA "
    ## Then
    check:
      cursors[0] == some(kvs[6].messageHash)
      cursors[1] == none(WakuMessageHash)

    check:
      pages[0] == kvs[0 .. 6]
      pages[1] == kvs[7 .. 9]

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())
    info "AAAAA "

  test "Store node history response - backward pagination":
    info "AAAAA "
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start())
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(archiveA)
    info "AAAAA "
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore()
    info "AAAAA "

    client.mountStoreClient()
    info "AAAAA "

    ## Given
    let req = StoreQueryRequest(
      includeData: true,
      contentTopics: @[DefaultContentTopic],
      paginationLimit: some(uint64(7)),
      paginationForward: PagingDirection.BACKWARD,
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    ## When
    var nextReq = req # copy
    info "AAAAA "

    var pages = newSeq[seq[WakuMessageKeyValue]](2)
    var cursors = newSeq[Option[WakuMessageHash]](2)
    info "AAAAA "

    for i in 0 ..< 2:
      info "AAAAA "
      let res = waitFor client.query(nextReq, peer = serverPeer)
      info "AAAAA "
      require res.isOk()
      info "AAAAA "

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.paginationCursor

      # Set/update the request cursor
      nextReq.paginationCursor = cursors[i]

    info "AAAAA "
    ## Then
    check:
      cursors[0] == some(kvs[3].messageHash)
      cursors[1] == none(WakuMessageHash)

    check:
      pages[0] == kvs[3 .. 9]
      pages[1] == kvs[0 .. 2]
    info "AAAAA "

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())
    info "AAAAA "

  test "Store protocol returns expected message when relay is disabled and filter enabled":
    ## See nwaku issue #937: 'Store: ability to decouple store from relay'
    info "AAAAA "
    ## Setup
    let
      filterSourceKey = generateSecp256k1Key()
      filterSource =
        newTestWakuNode(filterSourceKey, parseIpAddress("0.0.0.0"), Port(0))
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start(), filterSource.start())
    info "AAAAA "

    waitFor filterSource.mountFilter()
    let driver = newSqliteArchiveDriver()
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(driver)
    info "AAAAA "
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore()
    info "AAAAA "
    waitFor server.mountFilterClient()
    info "AAAAA "
    client.mountStoreClient()
    info "AAAAA "

    ## Given
    let message = fakeWakuMessage()
    info "AAAAA "
    let hash = computeMessageHash(DefaultPubSubTopic, message)
    info "AAAAA "
    let
      serverPeer = server.peerInfo.toRemotePeerInfo()
      filterSourcePeer = filterSource.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    ## Then
    let filterFut = newFuture[(PubsubTopic, WakuMessage)]()
    info "AAAAA "
    proc filterHandler(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ) {.async, gcsafe, closure.} =
      await server.wakuArchive.handleMessage(pubsubTopic, msg)
      filterFut.complete((pubsubTopic, msg))

    info "AAAAA "

    server.wakuFilterClient.registerPushHandler(filterHandler)
    let resp = waitFor server.filterSubscribe(
      some(DefaultPubsubTopic), DefaultContentTopic, peer = filterSourcePeer
    )
    info "AAAAA "

    waitFor sleepAsync(100.millis)

    waitFor filterSource.wakuFilter.handleMessage(DefaultPubsubTopic, message)

    # Wait for the server filter to receive the push message
    require waitFor filterFut.withTimeout(5.seconds)

    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let res = waitFor client.query(req, serverPeer)

    ## Then
    check res.isOk()

    let response = res.get()
    check:
      response.messages.len == 1
      response.messages[0] ==
        WakuMessageKeyValue(messageHash: hash, message: some(message))

    let (handledPubsubTopic, handledMsg) = filterFut.read()
    check:
      handledPubsubTopic == DefaultPubsubTopic
      handledMsg == message
    info "AAAAA "

    ## Cleanup
    waitFor allFutures(client.stop(), server.stop(), filterSource.stop())

  test "history query should return INVALID_CURSOR if the cursor has empty data in the request":
    ## Setup
    info "AAAAA "
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start())
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(archiveA)
    info "AAAAA "
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore()
    info "AAAAA "

    client.mountStoreClient()
    info "AAAAA "

    ## Forcing a bad cursor with empty digest data
    var cursor: WakuMessageHash = [
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
    ]
    info "AAAAA "

    ## Given
    let req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic], paginationCursor: some(cursor)
    )
    info "AAAAA "
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    ## When
    let queryRes = waitFor client.query(req, peer = serverPeer)
    info "AAAAA "

    ## Then
    check queryRes.isOk()
    info "AAAAA "

    let response = queryRes.get()
    info "AAAAA "

    check response.statusCode == 400
    info "AAAAA "
    check response.statusDesc == "BAD_REQUEST: invalid cursor"
    info "AAAAA "

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())
    info "AAAAA "

  test "Store protocol queries does not violate request rate limitation":
    info "AAAAA "
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start())
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(archiveA)
    info "AAAAA "
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore((4, 500.millis))
    info "AAAAA "

    client.mountStoreClient()
    info "AAAAA "

    ## Given
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    let requestProc = proc() {.async.} =
      let queryRes = waitFor client.query(req, peer = serverPeer)
      info "AAAAA "

      assert queryRes.isOk(), queryRes.error
      info "AAAAA "

      let response = queryRes.get()
      check:
        response.messages.mapIt(it.message) == msgListA
    info "AAAAA "

    for count in 0 ..< 4:
      info "AAAAA "
      waitFor requestProc()
      info "AAAAA "
      waitFor sleepAsync(20.millis)
      info "AAAAA "

    waitFor sleepAsync(500.millis)
    info "AAAAA "

    for count in 0 ..< 4:
      info "AAAAA "
      waitFor requestProc()
      info "AAAAA "
      waitFor sleepAsync(20.millis)
      info "AAAAA "
    info "AAAAA "

    # Cleanup

    waitFor allFutures(client.stop(), server.stop())
    info "AAAAA "

  test "Store protocol queries overrun request rate limitation":
    info "AAAAA "
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))
    info "AAAAA "

    waitFor allFutures(client.start(), server.start())
    info "AAAAA "

    let mountArchiveRes = server.mountArchive(archiveA)
    info "AAAAA "
    assert mountArchiveRes.isOk(), mountArchiveRes.error
    info "AAAAA "

    waitFor server.mountStore((3, 500.millis))
    info "AAAAA "

    client.mountStoreClient()
    info "AAAAA "

    ## Given
    let req = StoreQueryRequest(contentTopics: @[DefaultContentTopic])
    info "AAAAA "
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    info "AAAAA "

    let successProc = proc() {.async.} =
      let queryRes = waitFor client.query(req, peer = serverPeer)

      check queryRes.isOk()
      let response = queryRes.get()
      check:
        response.messages.mapIt(it.message) == msgListA
    info "AAAAA "
    let failsProc = proc() {.async.} =
      let queryRes = waitFor client.query(req, peer = serverPeer)

      check queryRes.isOk()
      let response = queryRes.get()

      check response.statusCode == 429

    for count in 0 ..< 3:
      info "AAAAA "
      waitFor successProc()
      waitFor sleepAsync(20.millis)

    info "AAAAA "
    waitFor failsProc()
    info "AAAAA "

    waitFor sleepAsync(500.millis)
    info "AAAAA "

    for count in 0 ..< 3:
      info "AAAAA "
      waitFor successProc()
      info "AAAAA "
      waitFor sleepAsync(20.millis)
      info "AAAAA "

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())
    info "AAAAA "
