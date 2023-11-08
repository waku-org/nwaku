{.used.}

import
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
  ../../../waku/common/databases/db_sqlite,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/sqlite_driver,
  ../../../waku/waku_store,
  ../../../waku/waku_filter,
  ../../../waku/waku_node,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

proc newTestArchiveDriver(): ArchiveDriver =
  let database = SqliteDatabase.new(":memory:").tryGet()
  SqliteDriver.new(database).tryGet()

proc computeTestCursor(pubsubTopic: PubsubTopic, message: WakuMessage): HistoryCursor =
  HistoryCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: waku_archive.computeDigest(message)
  )

procSuite "WakuNode - Store":
  ## Fixtures
  let timeOrigin = now()
  let msgListA = @[
    fakeWakuMessage(@[byte 00], ts=ts(00, timeOrigin)),
    fakeWakuMessage(@[byte 01], ts=ts(10, timeOrigin)),
    fakeWakuMessage(@[byte 02], ts=ts(20, timeOrigin)),
    fakeWakuMessage(@[byte 03], ts=ts(30, timeOrigin)),
    fakeWakuMessage(@[byte 04], ts=ts(40, timeOrigin)),
    fakeWakuMessage(@[byte 05], ts=ts(50, timeOrigin)),
    fakeWakuMessage(@[byte 06], ts=ts(60, timeOrigin)),
    fakeWakuMessage(@[byte 07], ts=ts(70, timeOrigin)),
    fakeWakuMessage(@[byte 08], ts=ts(80, timeOrigin)),
    fakeWakuMessage(@[byte 09], ts=ts(90, timeOrigin))
  ]

  let archiveA = block:
    let driver = newTestArchiveDriver()

    for msg in msgListA:
      let msg_digest = waku_archive.computeDigest(msg)
      let msg_hash = computeMessageHash(DefaultPubsubTopic, msg)
      require (waitFor driver.put(DefaultPubsubTopic, msg, msg_digest, msg_hash, msg.timestamp)).isOk()

    driver

  test "Store protocol returns expected messages":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let queryRes = waitFor client.query(req, peer=serverPeer)

    ## Then
    check queryRes.isOk()

    let response = queryRes.get()
    check:
      response.messages == msgListA

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store node history response - forward pagination":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], pageSize: 7, ascending: true)
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessage]](2)
    var cursors = newSeq[Option[HistoryCursor]](2)

    for i in 0..<2:
      let res = waitFor client.query(nextReq, peer=serverPeer)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.cursor

      # Set/update the request cursor
      nextReq.cursor = cursors[i]

    ## Then
    check:
      cursors[0] == some(computeTestCursor(DefaultPubsubTopic, msgListA[6]))
      cursors[1] == none(HistoryCursor)

    check:
      pages[0] == msgListA[0..6]
      pages[1] == msgListA[7..9]

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store node history response - backward pagination":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], pageSize: 7, ascending: false)
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessage]](2)
    var cursors = newSeq[Option[HistoryCursor]](2)

    for i in 0..<2:
      let res = waitFor client.query(nextReq, peer=serverPeer)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.cursor

      # Set/update the request cursor
      nextReq.cursor = cursors[i]

    ## Then
    check:
      cursors[0] == some(computeTestCursor(DefaultPubsubTopic, msgListA[3]))
      cursors[1] == none(HistoryCursor)

    check:
      pages[0] == msgListA[3..9]
      pages[1] == msgListA[0..2]

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store protocol returns expected message when relay is disabled and filter enabled":
    ## See nwaku issue #937: 'Store: ability to decouple store from relay'
    ## Setup
    let
      filterSourceKey = generateSecp256k1Key()
      filterSource = newTestWakuNode(filterSourceKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    waitFor allFutures(client.start(), server.start(), filterSource.start())

    waitFor filterSource.mountFilter()
    let driver = newTestArchiveDriver()

    let mountArchiveRes = server.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()
    waitFor server.mountFilterClient()
    client.mountStoreClient()

    ## Given
    let message = fakeWakuMessage()
    let
      serverPeer = server.peerInfo.toRemotePeerInfo()
      filterSourcePeer = filterSource.peerInfo.toRemotePeerInfo()

    ## Then
    let filterFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc filterHandler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe, closure.} =
      filterFut.complete((pubsubTopic, msg))

    waitFor server.legacyFilterSubscribe(some(DefaultPubsubTopic), DefaultContentTopic, filterHandler, peer=filterSourcePeer)

    waitFor sleepAsync(100.millis)

    # Send filter push message to server from source node
    waitFor filterSource.wakuFilterLegacy.handleMessage(DefaultPubsubTopic, message)

    # Wait for the server filter to receive the push message
    require waitFor filterFut.withTimeout(5.seconds)

    let res = waitFor client.query(HistoryQuery(contentTopics: @[DefaultContentTopic]), peer=serverPeer)

    ## Then
    check res.isOk()

    let response = res.get()
    check:
      response.messages.len == 1
      response.messages[0] == message

    let (handledPubsubTopic, handledMsg) = filterFut.read()
    check:
      handledPubsubTopic == DefaultPubsubTopic
      handledMsg == message

    ## Cleanup
    waitFor allFutures(client.stop(), server.stop(), filterSource.stop())
