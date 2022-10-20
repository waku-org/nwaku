{.used.}

import
  std/[options, tables, sets, times],
  stew/byteutils,
  testutils/unittests, 
  chronos, 
  chronicles,
  libp2p/switch,
  libp2p/crypto/crypto
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_store/client,
  ../../waku/v2/protocol/waku_store/protocol_metrics,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/time,
  ../test_helpers 


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")


proc now(): Timestamp =
  getNanosecondTime(getTime().toUnixFloat())

proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.init("", inMemory = true).tryGet()

proc fakeWakuMessage(
  payload = toBytes("TEST-PAYLOAD"),
  contentTopic = DefaultContentTopic, 
  ts = now(),
  ephemeral = false,
): WakuMessage = 
  WakuMessage(
    payload: payload,
    contentTopic: contentTopic,
    version: 1,
    timestamp: ts,
    ephemeral: ephemeral,
  )

proc newTestSwitch(key=none(PrivateKey), address=none(MultiAddress)): Switch =
  let peerKey = key.get(PrivateKey.random(ECDSA, rng[]).get())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()) 
  return newStandardSwitch(some(peerKey), addrs=peerAddr)

proc newTestStore(): MessageStore =
  let database = newTestDatabase()
  SqliteStore.init(database).tryGet()

proc newTestWakuStore(switch: Switch, store=newTestStore()): WakuStore =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuStore.init(peerManager, rng, store)

  waitFor proto.start()
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
      server = newTestWakuStore(serverSwitch, store=testStore)
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
      server = newTestWakuStore(serverSwitch, store=testStore)
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
      serverA = newTestWakuStore(serverSwitchA, store=testStore)
      serverB = newTestWakuStore(serverSwitchB, store=testStore)
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

  asyncTest "single query with no pre-configured store peer should fail":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let
      server = newTestWakuStore(serverSwitch, store=testStore)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 8)
    )

    ## When
    let res = await client.query(rpc)

    ## Then
    check:
      res.isErr()
      res.error == peerNotFoundFailure

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "single query to pre-configured store peer":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let
      server = newTestWakuStore(serverSwitch, store=testStore)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let peer = serverSwitch.peerInfo.toRemotePeerInfo()
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 8)
    )

    ## When
    client.setPeer(peer)

    let res = await client.query(rpc)

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
