{.used.}

import std/net, testutils/unittests, chronos, results

import
  logos_delivery/kernel/[
    peer_manager/peer_manager,
    api/kernel_lifecycle,
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/time,
    base/message,
    base/peers,
    base/codecs,
    protocols/store/resume,
    protocols/store/common,
    archive/driver,
  ],
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/wakunode,
  ./store_utils,
  ../waku_archive/archive_utils
suite "Store Resume":
  var resume {.threadvar.}: StoreResume

  asyncSetup:
    let resumeRes: Result[StoreResume, string] =
      StoreResume.new(peerManager = nil, wakuArchive = nil, wakuStoreClient = nil)

    assert resumeRes.isOk(), $resumeRes.error

    resume = resumeRes.get()

  asyncTeardown:
    await resume.stopWait()

  asyncTest "get set roundtrip":
    let ts = getNowInNanosecondTime()

    let setRes = resume.setLastOnlineTimestamp(ts)
    assert setRes.isOk(), $setRes.error

    let getRes = resume.getLastOnlineTimestamp()
    assert getRes.isOk(), $getRes.error

    let getTs = getRes.get()

    assert getTs == ts, "wrong timestamp"

suite "Store Resume - End to End":
  var server {.threadvar.}: Kernel
  var client {.threadvar.}: Kernel

  var serverDriver {.threadvar.}: ArchiveDriver
  var clientDriver {.threadvar.}: ArchiveDriver

  asyncSetup:
    let messages = @[
      fakeWakuMessage(@[byte 00]),
      fakeWakuMessage(@[byte 01]),
      fakeWakuMessage(@[byte 02]),
      fakeWakuMessage(@[byte 03]),
      fakeWakuMessage(@[byte 04]),
      fakeWakuMessage(@[byte 05]),
      fakeWakuMessage(@[byte 06]),
      fakeWakuMessage(@[byte 07]),
      fakeWakuMessage(@[byte 08]),
      fakeWakuMessage(@[byte 09]),
    ]

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, IPv4_any(), Port(0))
    client = newTestWakuNode(clientKey, IPv4_any(), Port(0))

    serverDriver = await newArchiveDriverWithMessages(DefaultPubsubTopic, messages)
    clientDriver = newSqliteArchiveDriver()

    let mountServerArchiveRes = server.mountArchive(serverDriver)
    let mountClientArchiveRes = client.mountArchive(clientDriver)

    assert mountServerArchiveRes.isOk()
    assert mountClientArchiveRes.isOk()

    await server.mountStore()
    await client.mountStore()

    client.mountStoreClient()
    server.mountStoreClient()

    client.setupStoreResume()

    (await server.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    let serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()

    client.peerManager.addServicePeer(serverRemotePeerInfo, WakuStoreCodec)

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  asyncTest "10 messages resume":
    var countRes = await clientDriver.getMessagesCount()
    assert countRes.isOk(), $countRes.error

    check:
      countRes.get() == 0

    (await client.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    countRes = await clientDriver.getMessagesCount()
    assert countRes.isOk(), $countRes.error

    check:
      countRes.get() == 10

suite "Store Resume - pages":
  var server {.threadvar.}: Kernel
  var client {.threadvar.}: Kernel
  var serverDriver {.threadvar.}: ArchiveDriver
  var clientDriver {.threadvar.}: ArchiveDriver

  asyncSetup:
    # 150 messages give the resume two pages of at most 100 messages. The
    # fifth message has a `meta` above `MaxMetaAttrLength`, and the 141st has a
    # content topic that is not valid UTF-8. The server stores both. Each page
    # has one of them, so the client drops one message from each page, and it
    # stores 148 messages.
    let base = now()
    var messages: seq[WakuMessage]
    for i in 0 ..< 150:
      let meta =
        if i == 4:
          newSeq[byte](MaxMetaAttrLength + 1)
        else:
          newSeq[byte]()
      let contentTopic = if i == 140: "/t\xff" else: DefaultContentTopic
      messages.add(
        fakeWakuMessage(
          @[byte i], contentTopic = contentTopic, meta = meta, ts = base + int64(i)
        )
      )

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, IPv4_any(), Port(0))
    client = newTestWakuNode(clientKey, IPv4_any(), Port(0))

    serverDriver = await newArchiveDriverWithMessages(DefaultPubsubTopic, messages)
    clientDriver = newSqliteArchiveDriver()

    assert server.mountArchive(serverDriver).isOk()
    assert client.mountArchive(clientDriver).isOk()

    await server.mountStore()
    await client.mountStore()
    client.mountStoreClient()
    client.setupStoreResume()

    (await server.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    client.peerManager.addServicePeer(
      server.peerInfo.toRemotePeerInfo(), WakuStoreCodec
    )

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  asyncTest "resume reads the pages after a page with a dropped message":
    check (await serverDriver.getMessagesCount()).get(0) == 150

    (await client.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    let count = await clientDriver.getMessagesCount()
    check:
      count.isOk()
      count.get(0) == 148
