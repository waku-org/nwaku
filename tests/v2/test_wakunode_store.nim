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
  ../../waku/common/sqlite,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_archive,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/utils/peers,
  ../../waku/v2/utils/time,
  ../../waku/v2/node/waku_node,
  ./testlib/common

from std/times import getTime, toUnixFloat


proc newTestArchiveDriver(): ArchiveDriver =
  let database = SqliteDatabase.new(":memory:").tryGet()
  SqliteDriver.new(database).tryGet()

proc put(store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage): Result[void, string] =
  let
    digest = waku_archive.computeDigest(message)
    receivedTime = if message.timestamp > 0: message.timestamp
                  else: getNanosecondTime(getTime().toUnixFloat())

  store.put(pubsubTopic, message, digest, receivedTime)


procSuite "WakuNode - Store":
  let rng = crypto.newRng()

  asyncTest "Store protocol returns expected message":
    ## Setup
    let
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60432))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60430))

    await allFutures(client.start(), server.start())

    let driver = newTestArchiveDriver()
    server.mountArchive(some(driver), none(MessageValidator), none(RetentionPolicy))
    await server.mountStore()

    client.mountStoreClient()

    ## Given
    let message = fakeWakuMessage()
    require driver.put(DefaultPubsubTopic, message).isOk()

    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic])
    let queryRes = await client.query(req, peer=serverPeer)

    ## Then
    check queryRes.isOk()

    let response = queryRes.get()
    check:
      response.messages == @[message]

    # Cleanup
    await allFutures(client.stop(), server.stop())

  asyncTest "Store protocol returns expected message when relay is disabled and filter enabled":
    ## See nwaku issue #937: 'Store: ability to decouple store from relay'
    ## Setup
    let
      filterSourceKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      filterSource = WakuNode.new(filterSourceKey, ValidIpAddress.init("0.0.0.0"), Port(60404))
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60402))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60400))

    await allFutures(client.start(), server.start(), filterSource.start())

    await filterSource.mountFilter()
    let driver = newTestArchiveDriver()
    server.mountArchive(some(driver), none(MessageValidator), none(RetentionPolicy))
    await server.mountStore()
    await server.mountFilterClient()
    client.mountStoreClient()

    ## Given
    let message = fakeWakuMessage()
    let
      serverPeer = server.peerInfo.toRemotePeerInfo()
      filterSourcePeer = filterSource.peerInfo.toRemotePeerInfo()

    ## Then
    let filterFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc filterHandler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.gcsafe, closure.} =
      filterFut.complete((pubsubTopic, msg))

    await server.filterSubscribe(DefaultPubsubTopic, DefaultContentTopic, filterHandler, peer=filterSourcePeer)

    await sleepAsync(100.millis)

    # Send filter push message to server from source node
    await filterSource.wakuFilter.handleMessage(DefaultPubsubTopic, message)

    # Wait for the server filter to receive the push message
    require await filterFut.withTimeout(5.seconds)

    let res = await client.query(HistoryQuery(contentTopics: @[DefaultContentTopic]), peer=serverPeer)

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
    await allFutures(client.stop(), server.stop(), filterSource.stop())
