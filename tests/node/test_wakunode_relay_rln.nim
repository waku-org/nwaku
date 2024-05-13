{.used.}

import
  std/tempfiles,
  stew/shims/net as stewNet,
  stew/results,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

from std/times import epochTime

import
  ../../../tools/rln_keystore_generator/rln_keystore_generator,
  ../../../waku/[
    node/waku_node,
    node/peer_manager,
    waku_core,
    waku_node,
    waku_rln_relay,
    waku_rln_relay/rln,
    waku_rln_relay/protocol_types,
    waku_keystore/keystore,
  ],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, wakunode, testasync, futures, common, assertions],
  ../resources/payloads,
  ../waku_rln_relay/[utils_static, utils_onchain],

from ../../waku/waku_noise/noise_utils import randomSeqByte
import os

proc addFakeMemebershipToKeystore(
    credentials: IdentityCredential,
    keystorePath: string,
    appInfo: AppInfo,
    rlnRelayEthContractAddress: string,
    password: string,
    membershipIndex: uint,
): IdentityCredential =
  # # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
  # var
  #   idTrapdoor = randomSeqByte(rng[], 32)
  #   idNullifier = randomSeqByte(rng[], 32)
  #   idSecretHash = randomSeqByte(rng[], 32)
  #   idCommitment = randomSeqByte(rng[], 32)
  #   idCredential = IdentityCredential(
  #     idTrapdoor: idTrapdoor,
  #     idNullifier: idNullifier,
  #     idSecretHash: idSecretHash,
  #     idCommitment: idCommitment,
  #   )

  var
    contract = MembershipContract(chainId: "1337", address: rlnRelayEthContractAddress)
    index = MembershipIndex(membershipIndex)

  let
    membershipCredential = KeystoreMembership(
      membershipContract: contract, treeIndex: index, identityCredential: credentials
    )
    persistRes = addMembershipCredentials(
      path = keystorePath,
      membership = membershipCredential,
      password = password,
      appInfo = appInfo,
    )

  assert persistRes.isOk()
  return credentials

proc getWakuRlnConfigOnChain*(
    keystorePath: string,
    appInfo: AppInfo,
    rlnRelayEthContractAddress: string,
    password: string,
    credIndex: uint,
): WakuRlnConfig =
  let
    # probably not needed
    # rlnInstance = createRlnInstance(
    #     tree_path = genTempPath("rln_tree", "group_manager_onchain")
    #   )
    #   .expect("Couldn't create RLN instance")
    keystoreRes = createAppKeystore(keystorePath, appInfo)

  assert keystoreRes.isOk()

  return WakuRlnConfig(
    rlnRelayEthClientAddress: EthClient,
    rlnRelayDynamic: true,
    # rlnRelayCredIndex: some(credIndex), # only needed to manually be set static
    rlnRelayCredIndex: some(credIndex), # remove
    rlnRelayEthContractAddress: rlnRelayEthContractAddress,
    rlnRelayCredPath: keystorePath,
    rlnRelayCredPassword: password,
    # rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $credIndex),
    rlnEpochSizeSec: 1,
  )

proc setupRelayWithOnChainRln*(
    node: WakuNode, pubsubTopics: seq[string], wakuRlnConfig: WakuRlnConfig
) {.async.} =
  await node.mountRelay(pubsubTopics)
  await node.mountRlnRelay(wakuRlnConfig)

suite "Waku RlnRelay - End to End - Static":
  var
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic

  var
    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

  var
    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerId {.threadvar.}: PeerId

  asyncSetup:
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())

    serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
    clientPeerId = client.switch.peerInfo.toRemotePeerInfo().peerId

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  suite "Mount":
    asyncTest "Can't mount if relay is not mounted":
      # Given Relay and RLN are not mounted
      check:
        server.wakuRelay == nil
        server.wakuRlnRelay == nil

      # When RlnRelay is mounted
      let catchRes = catch:
        await server.setupStaticRln(1)

      # Then Relay and RLN are not mounted,and the process fails
      check:
        server.wakuRelay == nil
        server.wakuRlnRelay == nil
        catchRes.error()[].msg ==
          "WakuRelay protocol is not mounted, cannot mount WakuRlnRelay"

    asyncTest "Pubsub topics subscribed before mounting RlnRelay are added to it":
      # Given the node enables Relay and Rln while subscribing to a pubsub topic
      await server.setupRelayWithStaticRln(1.uint, @[pubsubTopic])
      await client.setupRelayWithStaticRln(2.uint, @[pubsubTopic])
      check:
        server.wakuRelay != nil
        server.wakuRlnRelay != nil
        client.wakuRelay != nil
        client.wakuRlnRelay != nil

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # And the node registers the completion handler
      var completionFuture = subscribeCompletionHandler(server, pubsubTopic)

      # When the client sends a valid RLN message
      let isCompleted1 =
        await sendRlnMessage(client, pubsubTopic, contentTopic, completionFuture)

      # Then the valid RLN message is relayed
      check:
        isCompleted1
        completionFuture.read()

      # When the client sends an invalid RLN message
      completionFuture = newBoolFuture()
      let isCompleted2 = await sendRlnMessageWithInvalidProof(
        client, pubsubTopic, contentTopic, completionFuture
      )

      # Then the invalid RLN message is not relayed
      check:
        not isCompleted2

    asyncTest "Pubsub topics subscribed after mounting RlnRelay are added to it":
      # Given the node enables Relay and Rln without subscribing to a pubsub topic
      await server.setupRelayWithStaticRln(1.uint, @[])
      await client.setupRelayWithStaticRln(2.uint, @[])

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # await sleepAsync(FUTURE_TIMEOUT)
      # And the node registers the completion handler
      var completionFuture = subscribeCompletionHandler(server, pubsubTopic)

      await sleepAsync(FUTURE_TIMEOUT)
      # When the client sends a valid RLN message
      let isCompleted1 =
        await sendRlnMessage(client, pubsubTopic, contentTopic, completionFuture)

      # Then the valid RLN message is relayed
      check:
        isCompleted1
        completionFuture.read()

      # When the client sends an invalid RLN message
      completionFuture = newBoolFuture()
      let isCompleted2 = await sendRlnMessageWithInvalidProof(
        client, pubsubTopic, contentTopic, completionFuture
      )

      # Then the invalid RLN message is not relayed
      check:
        not isCompleted2

    asyncTest "rln-relay-max-message-limit testing":
      let
        nodekey = generateSecp256k1Key()
        node = newTestWakuNode(nodekey, parseIpAddress("0.0.0.0"), Port(0))

      await node.mountRelay(@[DefaultPubsubTopic])

      let contractAddress = await uploadRLNContract(EthClient)
      let wakuRlnConfig = WakuRlnConfig(
        rlnRelayDynamic: true,
        rlnRelayCredIndex: some(0.uint),
        rlnRelayUserMessageLimit: 111,
        rlnRelayTreepath: genTempPath("rln_tree", "wakunode_0"),
        rlnRelayEthClientAddress: EthClient,
        rlnRelayEthContractAddress: $contractAddress,
        rlnRelayChainId: 1337,
        onFatalErrorAction: proc(errStr: string) =
          raiseAssert errStr
        ,
      )

      try:
        await node.mountRlnRelay(wakuRlnConfig)
      except CatchableError as e:
        check e.msg ==
          "failed to mount WakuRlnRelay: rln-relay-user-message-limit can't exceed the MAX_MESSAGE_LIMIT in the rln contract"

  suite "Analysis of Bandwith Limitations":
    asyncTest "Valid Payload Sizes":
      # Given the node enables Relay and Rln while subscribing to a pubsub topic
      await server.setupRelayWithStaticRln(1.uint, @[pubsubTopic])
      await client.setupRelayWithStaticRln(2.uint, @[pubsubTopic])

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # Register Relay Handler
      var completionFut = newPushHandlerFuture()
      proc relayHandler(
          topic: PubsubTopic, msg: WakuMessage
      ): Future[void] {.async, gcsafe.} =
        if topic == pubsubTopic:
          completionFut.complete((topic, msg))

      let subscriptionEvent = (kind: PubsubSub, topic: pubsubTopic)
      server.subscribe(subscriptionEvent, some(relayHandler))
      await sleepAsync(FUTURE_TIMEOUT)

      # Generate Messages
      let
        epoch = epochTime()
        payload1b = getByteSequence(1)
        payload1kib = getByteSequence(1024)
        overhead: uint64 = 419
        payload150kib = getByteSequence((150 * 1024) - overhead)
        payload150kibPlus = getByteSequence((150 * 1024) - overhead + 1)

      var
        message1b = WakuMessage(payload: @payload1b, contentTopic: contentTopic)
        message1kib = WakuMessage(payload: @payload1kib, contentTopic: contentTopic)
        message150kib = WakuMessage(payload: @payload150kib, contentTopic: contentTopic)
        message151kibPlus =
          WakuMessage(payload: @payload150kibPlus, contentTopic: contentTopic)

      doAssert(
        client.wakuRlnRelay
        .appendRLNProof(
          message1b, epoch + float64(client.wakuRlnRelay.rlnEpochSizeSec * 0)
        )
        .isOk()
      )
      doAssert(
        client.wakuRlnRelay
        .appendRLNProof(
          message1kib, epoch + float64(client.wakuRlnRelay.rlnEpochSizeSec * 1)
        )
        .isOk()
      )
      doAssert(
        client.wakuRlnRelay
        .appendRLNProof(
          message150kib, epoch + float64(client.wakuRlnRelay.rlnEpochSizeSec * 2)
        )
        .isOk()
      )
      doAssert(
        client.wakuRlnRelay
        .appendRLNProof(
          message151kibPlus, epoch + float64(client.wakuRlnRelay.rlnEpochSizeSec * 3)
        )
        .isOk()
      )

      # When sending the 1B message
      discard await client.publish(some(pubsubTopic), message1b)
      discard await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

      # Then the message is relayed
      check completionFut.read() == (pubsubTopic, message1b)
      # When sending the 1KiB message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message1kib)
      discard await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

      # Then the message is relayed
      check completionFut.read() == (pubsubTopic, message1kib)

      # When sending the 150KiB message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message150kib)
      discard await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

      # Then the message is relayed
      check completionFut.read() == (pubsubTopic, message150kib)

      # When sending the 150KiB plus message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message151kibPlus)

      # Then the message is not relayed
      check not await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

    asyncTest "Invalid Payload Sizes":
      # Given the node enables Relay and Rln while subscribing to a pubsub topic
      await server.setupRelayWithStaticRln(1.uint, @[pubsubTopic])
      await client.setupRelayWithStaticRln(2.uint, @[pubsubTopic])

      # And the nodes are connected
      await client.connectToNodes(@[serverRemotePeerInfo])

      # Register Relay Handler
      var completionFut = newPushHandlerFuture()
      proc relayHandler(
          topic: PubsubTopic, msg: WakuMessage
      ): Future[void] {.async, gcsafe.} =
        if topic == pubsubTopic:
          completionFut.complete((topic, msg))

      let subscriptionEvent = (kind: PubsubSub, topic: pubsubTopic)
      server.subscribe(subscriptionEvent, some(relayHandler))
      await sleepAsync(FUTURE_TIMEOUT)

      # Generate Messages
      let
        epoch = epochTime()
        overhead: uint64 = 419
        payload150kibPlus = getByteSequence((150 * 1024) - overhead + 1)

      var message151kibPlus =
        WakuMessage(payload: @payload150kibPlus, contentTopic: contentTopic)

      doAssert(
        client.wakuRlnRelay
        .appendRLNProof(
          message151kibPlus, epoch + float64(client.wakuRlnRelay.rlnEpochSizeSec * 3)
        )
        .isOk()
      )

      # When sending the 150KiB plus message
      completionFut = newPushHandlerFuture() # Reset Future
      discard await client.publish(some(pubsubTopic), message151kibPlus)

      # Then the message is not relayed
      check not await completionFut.withTimeout(FUTURE_TIMEOUT_LONG)

suite "Waku RlnRelay - End to End - OnChain":
  let runAnvil {.used.} = runAnvil()

  var
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic

  var
    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

  var
    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerId {.threadvar.}: PeerId

  asyncSetup:
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())

    serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
    clientPeerId = client.switch.peerInfo.toRemotePeerInfo().peerId

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  # asyncTest "No valid contract":
  #   let
  #     invalidContractAddress = "0x0000000000000000000000000000000000000000"
  #     keystorePath =
  #       genTempPath("rln_keystore", "test_wakunode_relay_rln-no_valid_contract")
  #     appInfo = RlnAppInfo
  #     password = "1234"
  #     wakuRlnConfig1 = getWakuRlnConfigOnChain(
  #       keystorePath, appInfo, invalidContractAddress, password, 1
  #     )
  #     wakuRlnConfig2 = getWakuRlnConfigOnChain(
  #       keystorePath, appInfo, invalidContractAddress, password, 2
  #     )
  #     credentials = addFakeMemebershipToKeystore(
  #       keystorePath, appInfo, invalidContractAddress, password, 1
  #     )

  #   # Given the node enables Relay and Rln while subscribing to a pubsub topic
  #   try:
  #     await server.setupRelayWithOnChainRln(@[pubsubTopic], wakuRlnConfig1)
  #     assert false, "Relay should fail mounting when using an invalid contract"
  #   except CatchableError:
  #     assert true

  #   try:
  #     await client.setupRelayWithOnChainRln(@[pubsubTopic], wakuRlnConfig2)
  #     assert false, "Relay should fail mounting when using an invalid contract"
  #   except CatchableError:
  #     assert true

  asyncTest "Valid contract":
    echo "# 1"
    let
      onChainGroupManager = await setup()
      contractAddress = onChainGroupManager.ethContractAddress
      keystorePath =
        genTempPath("rln_keystore", "test_wakunode_relay_rln-valid_contract")
      appInfo = RlnAppInfo
      password = "1234"

    let keystoreRes = createAppKeystore(keystorePath, appInfo)
    assert keystoreRes.isOk()

    # TODO: how do I register creds or groupmanager on contract?

    let rlnInstance = createRlnInstance(
        tree_path =
          # genTempPath("rln_instance", "test_wakunode_relay_rln-valid_contract")
          genTempPath("rln_tree", "group_manager_onchain")
      )
      .expect("Couldn't create RLN instance")

    # Generate configs before registering the credentials. Otherwise the file gets cleared up.
    let
      wakuRlnConfig1 =
        getWakuRlnConfigOnChain(keystorePath, appInfo, contractAddress, password, 0)
      wakuRlnConfig2 =
        getWakuRlnConfigOnChain(keystorePath, appInfo, contractAddress, password, 1)

    let
      credentialRes1 = rlnInstance.membershipKeyGen()
      # credentialRes2 = rlnInstance.membershipKeyGen()

    if credentialRes1.isErr():
      error "failure while generating credentials", error = credentialRes1.error
      quit(1)

    # if credentialRes2.isErr():
    #   error "failure while generating credentials", error = credentialRes2.error
    #   quit(1)

    let
      idCredential1 = credentialRes1.get()
      # idCredential2 = credentialRes2.get()

    echo "-: ", idCredential1.idCommitment.toUInt256()
    await onChainGroupManager.init()
    try:
      waitFor onChainGroupManager.register(idCredential1)
      # waitFor onChainGroupManager.register(credentials2)
    except Exception:
      assert false, "Failed to register credentials: " & getCurrentExceptionMsg()

    let credentialIndex1 = onChainGroupManager.membershipIndex.get()
    echo "-----------", credentialIndex1
    let
      credentials1 = addFakeMemebershipToKeystore(
        idCredential1, keystorePath, appInfo, contractAddress, password,
        credentialIndex1,
      )
      # credentials2 = addFakeMemebershipToKeystore(
      #   idCredential2, keystorePath, appInfo, contractAddress, password, 2
      # )

    await onChainGroupManager.stop()
    # let
    #   contractAddress = $(await uploadRLNContract(EthClient))
    #   keystorePath =
    #     genTempPath("rln_keystore", "test_wakunode_relay_rln-no_valid_contract")
    #   appInfo = RlnAppInfo
    #   password = "1234"
    #   wakuRlnConfig1 =
    #     getWakuRlnConfigOnChain(keystorePath, appInfo, contractAddress, password, 1)
    #   wakuRlnConfig2 =
    #     getWakuRlnConfigOnChain(keystorePath, appInfo, contractAddress, password, 2)
    #   credentials = addFakeMemebershipToKeystore(
    #     keystorePath, appInfo, contractAddress, password, 1
    #   )
    # echo "######################"

    # let
    #   rlnInstance = createRlnInstance(
    #       tree_path = genTempPath("rln_tree", "group_manager_onchain")
    #     )
    #     .expect("Couldn't create RLN instance")
    #   keystoreRes = createAppKeystore(keystorePath, appInfo)
    # var idCredential = generateCredentials(rlnInstance)
    # assert keystoreRes.isOk()

    # let wakuRlnConfig1 = WakuRlnConfig(
    #   rlnRelayEthClientAddress: EthClient,
    #   rlnRelayDynamic: true,
    #   rlnRelayCredIndex: some(MembershipIndex(1)),
    #   rlnRelayEthContractAddress: contractAddress,
    #   rlnRelayCredPath: keystorePath,
    #   rlnRelayCredPassword: password,
    #   rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $1),
    #   rlnEpochSizeSec: 1,
    # )
    # let wakuRlnConfig2 = WakuRlnConfig(
    #   rlnRelayEthClientAddress: EthClient,
    #   rlnRelayDynamic: true,
    #   rlnRelayCredIndex: some(MembershipIndex(2)),
    #   rlnRelayEthContractAddress: contractAddress,
    #   rlnRelayCredPath: keystorePath,
    #   rlnRelayCredPassword: password,
    #   rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $2),
    #   rlnEpochSizeSec: 1,
    # )

    # var
    #   contract = MembershipContract(chainId: "5", address: contractAddress)
    #   index = MembershipIndex(1)

    # let
    #   membershipCredential = KeystoreMembership(
    #     membershipContract: contract, treeIndex: index, identityCredential: idCredential
    #   )
    #   keystoreRes2 = addMembershipCredentials(
    #     path = keystorePath,
    #     membership = membershipCredential,
    #     password = password,
    #     appInfo = appInfo,
    #   )

    # assert keystoreRes2.isOk()

    # echo "######################"

    echo "sleep2a"
    # await sleepAsync(30.seconds)
    echo "sleep2b"

    echo "# 2"
    # Given the node enables Relay and Rln while subscribing to a pubsub topic
    await server.setupRelayWithOnChainRln(@[pubsubTopic], wakuRlnConfig1)
    # echo "# 3"
    # await client.setupRelayWithOnChainRln(@[pubsubTopic], wakuRlnConfig2)
    # echo "# 4"

    # let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()

    # # And the nodes are connected
    # await client.connectToNodes(@[serverRemotePeerInfo])

    # # And the node registers the completion handler
    # var completionFuture = subscribeCompletionHandler(server, pubsubTopic)

    # # When the client sends a valid RLN message
    # let isCompleted1 =
    #   await sendRlnMessage(client, pubsubTopic, contentTopic, completionFuture)

    # # Then the valid RLN message is relayed
    # check:
    #   isCompleted1
    #   completionFuture.read()

  asyncTest "Valid contract with insufficient gas":
    discard

  ################################
  ## Terminating/removing Anvil
  ################################

  # We stop Anvil daemon
  stopAnvil(runAnvil)
