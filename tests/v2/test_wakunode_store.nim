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
  ../../waku/v2/node/storage/message/message_store,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/utils/pagination,
  ../../waku/v2/utils/time,
  ../../waku/v2/node/wakunode2

from std/times import getTime, toUnixFloat

proc newTestMessageStore(): MessageStore =
  let database = SqliteDatabase.init("", inMemory = true)[]
  SqliteStore.init(database).tryGet()


procSuite "WakuNode - Store":
  let rng = crypto.newRng()
 
  asyncTest "Store protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    await node1.mountStore(store=newTestMessageStore())
    await node2.start()
    await node2.mountStore(store=newTestMessageStore())

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(500.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

    proc storeHandler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages[0] == message
      completionFut.complete(true)

    await node1.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic)]), storeHandler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Store protocol returns expected message when relay is disabled and filter enabled":
    # See nwaku issue #937: 'Store: ability to decouple store from relay'

    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))

    let 
      pubSubTopic = "/waku/2/default-waku/proto"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    let
      filterComplFut = newFuture[bool]()
      storeComplFut = newFuture[bool]()

    await node1.start()
    await node1.mountStore(store=newTestMessageStore())
    await node1.mountFilter()

    await node2.start()
    await node2.mountStore(store=newTestMessageStore())
    await node2.mountFilter()

    node2.wakuFilter.setPeer(node1.switch.peerInfo.toRemotePeerInfo())
    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

    proc filterReqHandler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg == message
      filterComplFut.complete(true)

    await node2.subscribe(FilterRequest(pubSubTopic: pubSubTopic, contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true), filterReqHandler)

    await sleepAsync(500.millis)

    # Send filter push message to node2
    await node1.wakuFilter.handleMessage(pubSubTopic, message)

    await sleepAsync(500.millis)

    # Wait for the node2 filter to receive the push message
    check:
      (await filterComplFut.withTimeout(5.seconds)) == true

    proc node1StoreQueryRespHandler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len == 1
        response.messages[0] == message
      storeComplFut.complete(true)

    await node1.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic)]), node1StoreQueryRespHandler)

    check:
      (await storeComplFut.withTimeout(5.seconds)) == true

    await node1.stop()
    await node2.stop()

  asyncTest "Resume proc fetches the history":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
    
    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    await node1.start()
    await node1.mountStore(store=newTestMessageStore())
    await node2.start()
    await node2.mountStore(store=StoreQueueRef.new())

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(500.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

    await node1.resume()

    check:
      # message is correctly stored
      node1.wakuStore.store.getMessagesCount().tryGet() == 1

    await node1.stop()
    await node2.stop()

  asyncTest "Resume proc discards duplicate messages":
    let timeOrigin = getNanosecondTime(getTime().toUnixFloat())
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      client = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      server = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))

    let 
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      msg1 = WakuMessage(payload: "hello world1".toBytes(), contentTopic: contentTopic, timestamp: timeOrigin + 1)
      msg2 = WakuMessage(payload: "hello world2".toBytes(), contentTopic: contentTopic, timestamp: timeOrigin + 2)
      msg3 = WakuMessage(payload: "hello world3".toBytes(), contentTopic: contentTopic, timestamp: timeOrigin + 3)

    await allFutures(client.start(), server.start())
    await client.mountStore(store=StoreQueueRef.new())
    await server.mountStore(store=StoreQueueRef.new())

    await server.wakuStore.handleMessage(DefaultTopic, msg1)
    await server.wakuStore.handleMessage(DefaultTopic, msg2)

    client.wakuStore.setPeer(server.switch.peerInfo.toRemotePeerInfo())

    # Insert the same message in both node's store
    let index3 = Index.compute(msg3, getNanosecondTime(getTime().toUnixFloat() + 10.float), DefaultTopic)
    require server.wakuStore.store.put(index3, msg3, DefaultTopic).isOk()
    require client.wakuStore.store.put(index3, msg3, DefaultTopic).isOk()

    # now run the resume proc
    await client.resume()

    check:
      # If the duplicates are discarded properly, then the total number of messages after resume should be 3
      client.wakuStore.store.getMessagesCount().tryGet() == 3

    await allFutures(client.stop(), server.stop())