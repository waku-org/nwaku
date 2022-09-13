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
  libp2p/protocols/pubsub/gossipsub,
  eth/keys
import
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/protocol/[waku_relay, waku_message],
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/utils/pagination,
  ../../waku/v2/utils/time,
  ../../waku/v2/node/wakunode2

from std/times import epochTime


procSuite "WakuNode - Store":
  let rng = keys.newRng()
 
  asyncTest "Store protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    await node1.mountStore(persistMessages = true)
    await node2.start()
    await node2.mountStore(persistMessages = true)

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
    await node1.mountStore(persistMessages = true)
    await node1.mountFilter()

    await node2.start()
    await node2.mountStore(persistMessages = true)
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
    await node1.mountStore(persistMessages = true)
    await node2.start()
    await node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(500.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

    await node1.resume()

    check:
      # message is correctly stored
      node1.wakuStore.messages.len == 1

    await node1.stop()
    await node2.stop()

  asyncTest "Resume proc discards duplicate messages":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))

    let 
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      msg1 = WakuMessage(payload: "hello world1".toBytes(), contentTopic: contentTopic, timestamp: 1)
      msg2 = WakuMessage(payload: "hello world2".toBytes(), contentTopic: contentTopic, timestamp: 2)

    # setup sqlite database for node1
    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = SqliteStore.init(database).tryGet()

    await node1.start()
    await node1.mountStore(persistMessages = true, store = store)
    await node2.start()
    await node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage(DefaultTopic, msg1)
    await node2.wakuStore.handleMessage(DefaultTopic, msg2)

    await sleepAsync(500.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())


    # populate db with msg1 to be a duplicate
    let index1 = Index.compute(msg1, getNanosecondTime(epochTime()), DefaultTopic)
    let output1 = store.put(index1, msg1, DefaultTopic)
    check output1.isOk
    discard node1.wakuStore.messages.put(index1, msg1, DefaultTopic)

    # now run the resume proc
    await node1.resume()

    # count the total number of retrieved messages from the database
    let res = store.getAllMessages()
    check:
      res.isOk()

    check:
      # if the duplicates are discarded properly, then the total number of messages after resume should be 2
      # check no duplicates is in the messages field
      node1.wakuStore.messages.len == 2
      # check no duplicates is in the db
      res.value.len == 2

    await node1.stop()
    await node2.stop()