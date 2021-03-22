{.used.}

import
  std/[unittest, options, os, strutils],
  stew/byteutils, json_rpc/[rpcserver, rpcclient],
  eth/common as eth_common, eth/[rlp, keys, p2p],
  ../../waku/v1/protocol/waku_protocol,
  ../../waku/v1/node/rpc/[hexstrings, rpc_types, waku, key_storage]

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
## Generate client convenience marshalling wrappers from forward declarations
## For testing, ethcallsigs needs to be kept in sync with ../waku/node/v1/rpc/waku
const sigPath = sourceDir / ParDir / ParDir / "waku" / "v1" / "node" / "rpc" / "wakucallsigs.nim"
createRpcSigs(RpcSocketClient, sigPath)

proc setupNode(capabilities: varargs[ProtocolInfo, `protocolInfo`],
    rng: ref BrHmacDrbgContext, ): EthereumNode =
  let
    keypair = KeyPair.random(rng[])
    srvAddress = Address(ip: parseIpAddress("0.0.0.0"), tcpPort: Port(30303),
      udpPort: Port(30303))

  result = newEthereumNode(keypair, srvAddress, NetworkId(1), nil, "waku test rpc",
    addAllCapabilities = false, rng = rng)
  for capability in capabilities:
    result.addCapability capability

proc doTests {.async.} =
  let rng = keys.newRng()
  var ethNode = setupNode(Waku, rng)

  # Create Ethereum RPCs
  let rpcPort = 8545
  var
    rpcServer = newRpcSocketServer(["localhost:" & $rpcPort])
    client = newRpcSocketClient()
  let keys = newKeyStorage()
  setupWakuRPC(ethNode, keys, rpcServer, rng)

  # Begin tests
  rpcServer.start()
  await client.connect("localhost", Port(rpcPort))

  suite "Waku Remote Procedure Calls":
    test "waku_version":
      check await(client.waku_version()) == wakuVersionStr
    test "waku_info":
      let info = await client.waku_info()
      check info.maxMessageSize == defaultMaxMsgSize
    test "waku_setMaxMessageSize":
      let testValue = 1024'u64
      check await(client.waku_setMaxMessageSize(testValue)) == true
      var info = await client.waku_info()
      check info.maxMessageSize == testValue
      expect ValueError:
        discard await(client.waku_setMaxMessageSize(defaultMaxMsgSize + 1))
      info = await client.waku_info()
      check info.maxMessageSize == testValue
    test "waku_setMinPoW":
      let testValue = 0.0001
      check await(client.waku_setMinPoW(testValue)) == true
      let info = await client.waku_info()
      check info.minPow == testValue
    # test "waku_markTrustedPeer":
      # TODO: need to connect a peer to test
    test "waku asymKey tests":
      let keyID = await client.waku_newKeyPair()
      check:
        await(client.waku_hasKeyPair(keyID)) == true
        await(client.waku_deleteKeyPair(keyID)) == true
        await(client.waku_hasKeyPair(keyID)) == false
      expect ValueError:
        discard await(client.waku_deleteKeyPair(keyID))

      let privkey = "0x5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3"
      let pubkey = "0x04e5fd642a0f630bbb1e4cd7df629d7b8b019457a9a74f983c0484a045cebb176def86a54185b50bbba6bbf97779173695e92835d63109c23471e6da382f922fdb"
      let keyID2 = await client.waku_addPrivateKey(privkey)
      check:
        await(client.waku_getPublicKey(keyID2)) == pubkey.toPublicKey
        await(client.waku_getPrivateKey(keyID2)).toRaw() == privkey.toPrivateKey.toRaw()
        await(client.waku_hasKeyPair(keyID2)) == true
        await(client.waku_deleteKeyPair(keyID2)) == true
        await(client.waku_hasKeyPair(keyID2)) == false
      expect ValueError:
        discard await(client.waku_deleteKeyPair(keyID2))
    test "waku symKey tests":
      let keyID = await client.waku_newSymKey()
      check:
        await(client.waku_hasSymKey(keyID)) == true
        await(client.waku_deleteSymKey(keyID)) == true
        await(client.waku_hasSymKey(keyID)) == false
      expect ValueError:
        discard await(client.waku_deleteSymKey(keyID))

      let symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
      let keyID2 = await client.waku_addSymKey(symKey)
      check:
        await(client.waku_getSymKey(keyID2)) == symKey.toSymKey
        await(client.waku_hasSymKey(keyID2)) == true
        await(client.waku_deleteSymKey(keyID2)) == true
        await(client.waku_hasSymKey(keyID2)) == false
      expect ValueError:
        discard await(client.waku_deleteSymKey(keyID2))

      let keyID3 = await client.waku_generateSymKeyFromPassword("password")
      let keyID4 = await client.waku_generateSymKeyFromPassword("password")
      let keyID5 = await client.waku_generateSymKeyFromPassword("nimbus!")
      check:
        await(client.waku_getSymKey(keyID3)) ==
          await(client.waku_getSymKey(keyID4))
        await(client.waku_getSymKey(keyID3)) !=
          await(client.waku_getSymKey(keyID5))
        await(client.waku_hasSymKey(keyID3)) == true
        await(client.waku_deleteSymKey(keyID3)) == true
        await(client.waku_hasSymKey(keyID3)) == false
      expect ValueError:
        discard await(client.waku_deleteSymKey(keyID3))

    # Some defaults for the filter & post tests
    let
      ttl = 30'u64
      topicStr = "0x12345678"
      payload = "0x45879632"
      # A very low target and long time so we are sure the test never fails
      # because of this
      powTarget = 0.001
      powTime = 1.0

    test "waku filter create and delete":
      let
        topic = topicStr.toTopic()
        symKeyID = await client.waku_newSymKey()
        options = WakuFilterOptions(symKeyID: some(symKeyID),
                                       topics: some(@[topic]))
        filterID = await client.waku_newMessageFilter(options)

      check:
        filterID.string.isValidIdentifier
        await(client.waku_deleteMessageFilter(filterID)) == true
      expect ValueError:
        discard await(client.waku_deleteMessageFilter(filterID))

    test "waku symKey post and filter loop":
      let
        topic = topicStr.toTopic()
        symKeyID = await client.waku_newSymKey()
        options = WakuFilterOptions(symKeyID: some(symKeyID),
                                       topics: some(@[topic]))
        filterID = await client.waku_newMessageFilter(options)
        message = WakuPostMessage(symKeyID: some(symKeyID),
                                     ttl: ttl,
                                     topic: some(topic),
                                     payload: payload.HexDataStr,
                                     powTime: powTime,
                                     powTarget: powTarget)
      check:
        await(client.waku_setMinPoW(powTarget)) == true
        await(client.waku_post(message)) == true

      let messages = await client.waku_getFilterMessages(filterID)
      check:
        messages.len == 1
        messages[0].sig.isNone()
        messages[0].recipientPublicKey.isNone()
        messages[0].ttl == ttl
        messages[0].topic == topic
        messages[0].payload == hexToSeqByte(payload)
        messages[0].padding.len > 0
        messages[0].pow >= powTarget

        await(client.waku_deleteMessageFilter(filterID)) == true

    test "waku asymKey post and filter loop":
      let
        topic = topicStr.toTopic()
        privateKeyID = await client.waku_newKeyPair()
        options = WakuFilterOptions(privateKeyID: some(privateKeyID))
        filterID = await client.waku_newMessageFilter(options)
        pubKey = await client.waku_getPublicKey(privateKeyID)
        message = WakuPostMessage(pubKey: some(pubKey),
                                     ttl: ttl,
                                     topic: some(topic),
                                     payload: payload.HexDataStr,
                                     powTime: powTime,
                                     powTarget: powTarget)
      check:
        await(client.waku_setMinPoW(powTarget)) == true
        await(client.waku_post(message)) == true

      let messages = await client.waku_getFilterMessages(filterID)
      check:
        messages.len == 1
        messages[0].sig.isNone()
        messages[0].recipientPublicKey.get() == pubKey
        messages[0].ttl == ttl
        messages[0].topic == topic
        messages[0].payload == hexToSeqByte(payload)
        messages[0].padding.len > 0
        messages[0].pow >= powTarget

        await(client.waku_deleteMessageFilter(filterID)) == true

    test "waku signature in post and filter loop":
      let
        topic = topicStr.toTopic()
        symKeyID = await client.waku_newSymKey()
        privateKeyID = await client.waku_newKeyPair()
        pubKey = await client.waku_getPublicKey(privateKeyID)
        options = WakuFilterOptions(symKeyID: some(symKeyID),
                                       topics: some(@[topic]),
                                       sig: some(pubKey))
        filterID = await client.waku_newMessageFilter(options)
        message = WakuPostMessage(symKeyID: some(symKeyID),
                                     sig: some(privateKeyID),
                                     ttl: ttl,
                                     topic: some(topic),
                                     payload: payload.HexDataStr,
                                     powTime: powTime,
                                     powTarget: powTarget)
      check:
        await(client.waku_setMinPoW(powTarget)) == true
        await(client.waku_post(message)) == true

      let messages = await client.waku_getFilterMessages(filterID)
      check:
        messages.len == 1
        messages[0].sig.get() == pubKey
        messages[0].recipientPublicKey.isNone()
        messages[0].ttl == ttl
        messages[0].topic == topic
        messages[0].payload == hexToSeqByte(payload)
        messages[0].padding.len > 0
        messages[0].pow >= powTarget

        await(client.waku_deleteMessageFilter(filterID)) == true

  rpcServer.stop()
  rpcServer.close()

waitFor doTests()
