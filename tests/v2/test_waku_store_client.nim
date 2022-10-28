{.used.}

import
  std/[options, tables],
  testutils/unittests, 
  chronos, 
  chronicles,
  libp2p/crypto/crypto
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_store/client,
  ../../waku/v2/protocol/waku_store/protocol_metrics,
  ./testlib/common,
  ./testlib/switch


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestStore(): MessageStore =
  let database = newTestDatabase()
  SqliteStore.init(database).tryGet()

proc newTestWakuStoreNode(switch: Switch, store=newTestStore()): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuStore.new(peerManager, rng, store)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient(switch: Switch, store: MessageStore = nil): WakuStoreClient =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
  WakuStoreClient.new(peerManager, rng, store)


procSuite "Waku Store Client":

  ## Fixtures
  let testStore = block:
      let store = newTestStore()
      let msgList = @[
          fakeWakuMessage(payload= @[byte 0], contentTopic=ContentTopic("0")),
          fakeWakuMessage(payload= @[byte 1], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 2], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 3], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 4], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 5], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 6], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 7], contentTopic=DefaultContentTopic),
          fakeWakuMessage(payload= @[byte 8], contentTopic=DefaultContentTopic), 
          fakeWakuMessage(payload= @[byte 9], contentTopic=ContentTopic("9")),
          fakeWakuMessage(payload= @[byte 10], contentTopic=DefaultContentTopic), 
          fakeWakuMessage(payload= @[byte 11], contentTopic=ContentTopic("11")), 
          fakeWakuMessage(payload= @[byte 12], contentTopic=DefaultContentTopic), 
        ]

      for msg in msgList:
        assert store.put(DefaultPubsubTopic, msg).isOk()

      store
  
  asyncTest "single query to peer":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let
      server = await newTestWakuStoreNode(serverSwitch, store=testStore)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let peer = serverSwitch.peerInfo.toRemotePeerInfo()
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 8)
    )

    ## When
    let res = await client.query(rpc, peer)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      ## No pagination specified. Response will be auto-paginated with
      ## up to MaxPageSize messages per page.
      response.messages.len() == 8
      response.pagingInfo != PagingInfo()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "multiple query to peer with pagination":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let
      server = await newTestWakuStoreNode(serverSwitch, store=testStore)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let peer = serverSwitch.peerInfo.toRemotePeerInfo()
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 5)
    )

    ## When
    let res = await client.queryWithPaging(rpc, peer)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.len == 10

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "multiple query to multiple peers with pagination":
    ## Setup
    let 
      serverSwitchA = newTestSwitch()
      serverSwitchB = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitchA.start(), serverSwitchB.start(), clientSwitch.start())
      
    let
      serverA = await newTestWakuStoreNode(serverSwitchA, store=testStore)
      serverB = await newTestWakuStoreNode(serverSwitchB, store=testStore)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let peers = @[
      serverSwitchA.peerInfo.toRemotePeerInfo(),
      serverSwitchB.peerInfo.toRemotePeerInfo()
    ]
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 5)
    )

    ## When
    let res = await client.queryLoop(rpc, peers)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.len == 10

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitchA.stop(), serverSwitchB.stop())
