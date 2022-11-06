{.used.}

import
  std/[options, tables, sets],
  testutils/unittests, 
  chronos, 
  chronicles,
  libp2p/crypto/crypto
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/message_store/sqlite_store,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ./testlib/common,
  ./testlib/switch


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new("memory:").tryGet()

proc newTestMessageStore(): MessageStore =
  let database = newTestDatabase()
  SqliteStore.init(database).tryGet()

proc newTestWakuStore(switch: Switch, store=newTestMessageStore()): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuStore.init(peerManager, rng, store)

  await proto.start()
  switch.mount(proto)

  return proto


procSuite "Waku Store - resume store":
  ## Fixtures
  let storeA = block:
      let store = newTestMessageStore()
      let msgList = @[
        fakeWakuMessage(payload= @[byte 0], contentTopic=ContentTopic("2"), ts=ts(0)),
        fakeWakuMessage(payload= @[byte 1], contentTopic=ContentTopic("1"), ts=ts(1)),
        fakeWakuMessage(payload= @[byte 2], contentTopic=ContentTopic("2"), ts=ts(2)),
        fakeWakuMessage(payload= @[byte 3], contentTopic=ContentTopic("1"), ts=ts(3)),
        fakeWakuMessage(payload= @[byte 4], contentTopic=ContentTopic("2"), ts=ts(4)),
        fakeWakuMessage(payload= @[byte 5], contentTopic=ContentTopic("1"), ts=ts(5)),
        fakeWakuMessage(payload= @[byte 6], contentTopic=ContentTopic("2"), ts=ts(6)),
        fakeWakuMessage(payload= @[byte 7], contentTopic=ContentTopic("1"), ts=ts(7)),
        fakeWakuMessage(payload= @[byte 8], contentTopic=ContentTopic("2"), ts=ts(8)),
        fakeWakuMessage(payload= @[byte 9], contentTopic=ContentTopic("1"), ts=ts(9))
      ]

      for msg in msgList:
        require store.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

      store

  let storeB = block: 
      let store = newTestMessageStore()
      let msgList2 = @[
        fakeWakuMessage(payload= @[byte 0], contentTopic=ContentTopic("2"), ts=ts(0)),
        fakeWakuMessage(payload= @[byte 11], contentTopic=ContentTopic("1"), ts=ts(1)),
        fakeWakuMessage(payload= @[byte 12], contentTopic=ContentTopic("2"), ts=ts(2)),
        fakeWakuMessage(payload= @[byte 3], contentTopic=ContentTopic("1"), ts=ts(3)),
        fakeWakuMessage(payload= @[byte 4], contentTopic=ContentTopic("2"), ts=ts(4)),
        fakeWakuMessage(payload= @[byte 5], contentTopic=ContentTopic("1"), ts=ts(5)),
        fakeWakuMessage(payload= @[byte 13], contentTopic=ContentTopic("2"), ts=ts(6)),
        fakeWakuMessage(payload= @[byte 14], contentTopic=ContentTopic("1"), ts=ts(7))
      ]

      for msg in msgList2:
        require store.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

      store


  asyncTest "resume message history":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())

    let 
      server = await newTestWakuStore(serverSwitch, store=storeA)
      client = await newTestWakuStore(clientSwitch)

    client.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## When
    let res = await client.resume()

    ## Then
    check res.isOk()

    let resumedMessagesCount = res.tryGet()
    let storedMessagesCount = client.store.getMessagesCount().tryGet()
    check:
      resumedMessagesCount == 10
      storedMessagesCount == 10
    
    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "resume history from a list of candidates - offline peer":
    ## Setup
    let 
      clientSwitch = newTestSwitch()
      offlineSwitch = newTestSwitch()
    
    await clientSwitch.start()

    let client = await newTestWakuStore(clientSwitch)

    ## Given
    let peers = @[offlineSwitch.peerInfo.toRemotePeerInfo()]
    
    ## When
    let res = await client.resume(some(peers))

    ## Then
    check res.isErr()
    
    ## Cleanup
    await clientSwitch.stop()

  asyncTest "resume history from a list of candidates - online and offline peers":
    ## Setup
    let 
      offlineSwitch = newTestSwitch()
      serverASwitch = newTestSwitch()
      serverBSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverASwitch.start(), serverBSwitch.start(), clientSwitch.start())

    let 
      serverA = await newTestWakuStore(serverASwitch, store=storeA)
      serverB = await newTestWakuStore(serverBSwitch, store=storeB)
      client = await newTestWakuStore(clientSwitch)

    ## Given
    let peers = @[
      offlineSwitch.peerInfo.toRemotePeerInfo(),
      serverASwitch.peerInfo.toRemotePeerInfo(),
      serverBSwitch.peerInfo.toRemotePeerInfo()
    ]

    ## When
    let res = await client.resume(some(peers))
  
    ## Then
    # `client` is expected to retrieve 14 messages:
    # - The store mounted on `serverB` holds 10 messages (see `storeA` fixture)
    # - The store mounted on `serverB` holds 7 messages (see `storeB` fixture)
    # Both stores share 3 messages, resulting in 14 unique messages in total
    check res.isOk()

    let restoredMessagesCount = res.tryGet()
    let storedMessagesCount = client.store.getMessagesCount().tryGet()
    check:
      restoredMessagesCount == 14
      storedMessagesCount == 14
  
    ## Cleanup
    await allFutures(serverASwitch.stop(), serverBSwitch.stop(), clientSwitch.stop())

