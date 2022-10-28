{.used.}

import
  stew/byteutils, 
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
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/utils/time,
  ../../waku/v2/node/waku_node,
  ./testlib/common


proc newTestMessageStore(): MessageStore =
  let database = SqliteDatabase.new(":memory:").tryGet()
  SqliteStore.init(database).tryGet()


procSuite "WakuNode - Store":
  let rng = crypto.newRng()
 
  asyncTest "Store protocol returns expected message":
    ## Setup
    let
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60002))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60000))

    await allFutures(client.start(), server.start())
    await server.mountStore(store=newTestMessageStore())
    await client.mountStore()
    client.mountStoreClient()

    ## Given
    let message = fakeWakuMessage()
    require server.wakuStore.store.put(DefaultPubsubTopic, message).isOk()

    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)])
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
      filterSource = WakuNode.new(filterSourceKey, ValidIpAddress.init("0.0.0.0"), Port(60004))
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60002))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60000))

    await allFutures(client.start(), server.start(), filterSource.start())

    await filterSource.mountFilter()
    await server.mountStore(store=newTestMessageStore())
    await server.mountFilter()
    await client.mountStore()
    client.mountStoreClient()

    server.wakuFilter.setPeer(filterSource.peerInfo.toRemotePeerInfo())

    ## Given
    let message = fakeWakuMessage()
    let serverPeer = server.peerInfo.toRemotePeerInfo()
    ## Then
    let filterFut = newFuture[bool]()
    proc filterReqHandler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg == message
      filterFut.complete(true)

    let filterReq = FilterRequest(pubSubTopic: DefaultPubsubTopic, contentFilters: @[ContentFilter(contentTopic: DefaultContentTopic)], subscribe: true)
    await server.subscribe(filterReq, filterReqHandler)

    await sleepAsync(100.millis)

    # Send filter push message to server from source node
    await filterSource.wakuFilter.handleMessage(DefaultPubsubTopic, message)

    # Wait for the server filter to receive the push message
    require (await filterFut.withTimeout(5.seconds))

    let res = await client.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)]), peer=serverPeer)

    ## Then
    check res.isOk()

    let response = res.get()
    check:
      response.messages.len == 1
      response.messages[0] == message

    ## Cleanup
    await allFutures(client.stop(), server.stop(), filterSource.stop())


  asyncTest "Resume proc fetches the history":
    ## Setup
    let
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60002))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60000))

    await allFutures(client.start(), server.start())

    await server.mountStore(store=newTestMessageStore())
    
    let clientStore = StoreQueueRef.new()
    await client.mountStore(store=clientStore)
    client.mountStoreClient(store=clientStore)

    ## Given
    let message = fakeWakuMessage()
    require server.wakuStore.store.put(DefaultPubsubTopic, message).isOk()

    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    await client.resume(some(@[serverPeer]))

    # Then
    check:
      client.wakuStore.store.getMessagesCount().tryGet() == 1

    ## Cleanup
    await allFutures(client.stop(), server.stop())


  asyncTest "Resume proc discards duplicate messages":
    ## Setup
    let
      serverKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(60002))
      clientKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(60000))

    await allFutures(server.start(), client.start())
    await server.mountStore(store=StoreQueueRef.new())
    
    let clientStore = StoreQueueRef.new()
    await client.mountStore(store=clientStore)
    client.mountStoreClient(store=clientStore)

    ## Given
    let timeOrigin = now()
    let 
      msg1 = fakeWakuMessage(payload="hello world1", ts=(timeOrigin + getNanoSecondTime(1)))
      msg2 = fakeWakuMessage(payload="hello world2", ts=(timeOrigin + getNanoSecondTime(2)))
      msg3 = fakeWakuMessage(payload="hello world3", ts=(timeOrigin + getNanoSecondTime(3)))

    require server.wakuStore.store.put(DefaultTopic, msg1).isOk()
    require server.wakuStore.store.put(DefaultTopic, msg2).isOk()

    # Insert the same message in both node's store
    let 
      receivedTime3 = now() + getNanosecondTime(10)
      digest3 = computeDigest(msg3)
    require server.wakuStore.store.put(DefaultTopic, msg3, digest3, receivedTime3).isOk()
    require client.wakuStore.store.put(DefaultTopic, msg3, digest3, receivedTime3).isOk()

    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    await client.resume(some(@[serverPeer]))

    ## Then
    check:
      # If the duplicates are discarded properly, then the total number of messages after resume should be 3
      client.wakuStore.store.getMessagesCount().tryGet() == 3

    await allFutures(client.stop(), server.stop())