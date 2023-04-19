when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  chronicles,
  json_rpc/rpcserver,
  eth/keys,
  nimcrypto/sysrand
import
  ../../../../common/base64,
  ../../../waku_core,
  ../../../waku_relay,
  ../../../utils/compat,
  ../../waku_node,
  ../../message_cache,
  ./types


logScope:
  topics = "waku node jsonrpc relay_api"


const futTimeout* = 5.seconds # Max time to wait for futures

type
  MessageCache* = message_cache.MessageCache[PubsubTopic]


## Waku Relay JSON-RPC API

proc installRelayApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache) =
  if node.wakuRelay.isNil():
    debug "waku relay protocol is nil. skipping json rpc api handlers installation"
    return

  let topicHandler = proc(topic: PubsubTopic, message: WakuMessage) {.async.} =
      cache.addMessage(topic, message)

  # The node may already be subscribed to some topics when Relay API handlers
  # are installed
  for topic in node.wakuRelay.subscribedTopics:
    node.subscribe(topic, topicHandler)
    cache.subscribe(topic)


  server.rpc("post_waku_v2_relay_v1_subscriptions") do (topics: seq[PubsubTopic]) -> bool:
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"

    # Subscribe to all requested topics
    for topic in topics:
      if cache.isSubscribed(topic):
        continue

      cache.subscribe(topic)
      node.subscribe(topic, topicHandler)

    return true

  server.rpc("delete_waku_v2_relay_v1_subscriptions") do (topics: seq[PubsubTopic]) -> bool:
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"

    # Unsubscribe all handlers from requested topics
    for topic in topics:
      node.unsubscribeAll(topic)
      cache.unsubscribe(topic)

    return true

  server.rpc("post_waku_v2_relay_v1_message") do (topic: PubsubTopic, msg: WakuMessageRPC) -> bool:
    ## Publishes a WakuMessage to a PubSub topic
    debug "post_waku_v2_relay_v1_message"

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    let message = WakuMessage(
        payload: payloadRes.value,
        # TODO: Fail if the message doesn't have a content topic
        contentTopic: msg.contentTopic.get(DefaultContentTopic),
        version: msg.version.get(0'u32),
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )

    let publishFut = node.publish(topic, message)

    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to publish to topic " & topic)

    return true

  server.rpc("get_waku_v2_relay_v1_messages") do (topic: PubsubTopic) -> seq[WakuMessageRPC]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called
    debug "get_waku_v2_relay_v1_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    return msgRes.value.map(toWakuMessageRPC)


## Waku Relay Private JSON-RPC API (Whisper/Waku v1 compatibility)

func keyInfo(symkey: Option[SymKey], privateKey: Option[PrivateKey]): KeyInfo =
  if symkey.isSome():
    KeyInfo(kind: Symmetric, symKey: symkey.get())
  elif privateKey.isSome():
    KeyInfo(kind: Asymmetric, privKey: privateKey.get())
  else:
    KeyInfo(kind: KeyKind.None)

proc toWakuMessageRPC(message: WakuMessage,
                      symkey = none(SymKey),
                      privateKey = none(PrivateKey)): WakuMessageRPC =
  let
    keyInfo = keyInfo(symkey, privateKey)
    decoded = decodePayload(message, keyInfo)

  WakuMessageRPC(payload: base64.encode(decoded.get().payload),
                   contentTopic: some(message.contentTopic),
                   version: some(message.version),
                   timestamp: some(message.timestamp))


proc installRelayPrivateApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache) =

  server.rpc("get_waku_v2_private_v1_symmetric_key") do () -> SymKey:
    ## Generates and returns a symmetric key for message encryption and decryption
    debug "get_waku_v2_private_v1_symmetric_key"

    var key: SymKey
    if randomBytes(key) != key.len:
      raise newException(ValueError, "Failed generating key")

    return key

  server.rpc("post_waku_v2_private_v1_symmetric_message") do (topic: string, msg: WakuMessageRPC, symkey: string) -> bool:
    ## Publishes and encrypts a message to be relayed on a PubSub topic
    debug "post_waku_v2_private_v1_symmetric_message"

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    let payloadV1 = Payload(
        payload: payloadRes.value,
        dst: none(keys.PublicKey),
        symkey: some(symkey.toSymKey())
      )

    let encryptedPayloadRes = payloadV1.encode(1, node.rng[])
    if encryptedPayloadRes.isErr():
      raise newException(ValueError, "payload encryption failed: " & $encryptedPayloadRes.error)

    let message = WakuMessage(
        payload: encryptedPayloadRes.value,
        # TODO: Fail if the message doesn't have a content topic
        contentTopic: msg.contentTopic.get(DefaultContentTopic),
        version: 1,
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )

    let publishFut = node.publish(topic, message)
    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "publish to topic timed out")

    # Successfully published message
    return true

  server.rpc("get_waku_v2_private_v1_symmetric_messages") do (topic: string, symkey: string) -> seq[WakuMessageRPC]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called. Decrypts the message payloads
    ## before returning.
    debug "get_waku_v2_private_v1_symmetric_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "not subscribed to topic: " & topic)

    let msgs = msgRes.get()

    let key = some(symkey.toSymKey())
    return msgs.mapIt(it.toWakuMessageRPC(symkey=key))

  server.rpc("get_waku_v2_private_v1_asymmetric_keypair") do () -> WakuKeyPair:
    ## Generates and returns a public/private key pair for asymmetric message encryption and decryption.
    debug "get_waku_v2_private_v1_asymmetric_keypair"

    let privKey = keys.PrivateKey.random(node.rng[])

    return WakuKeyPair(seckey: privKey, pubkey: privKey.toPublicKey())

  server.rpc("post_waku_v2_private_v1_asymmetric_message") do (topic: string, msg: WakuMessageRPC, publicKey: string) -> bool:
    ## Publishes and encrypts a message to be relayed on a PubSub topic
    debug "post_waku_v2_private_v1_asymmetric_message"

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    let payloadV1 = Payload(
        payload: payloadRes.value,
        dst: some(publicKey.toPublicKey()),
        symkey: none(SymKey)
      )

    let encryptedPayloadRes = payloadV1.encode(1, node.rng[])
    if encryptedPayloadRes.isErr():
      raise newException(ValueError, "payload encryption failed: " & $encryptedPayloadRes.error)

    let message = WakuMessage(
        payload: encryptedPayloadRes.value,
        # TODO: Fail if the message doesn't have a content topic
        contentTopic: msg.contentTopic.get(DefaultContentTopic),
        version: 1,
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )

    let publishFut = node.publish(topic, message)
    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "publish to topic timed out")

    # Successfully published message
    return true

  server.rpc("get_waku_v2_private_v1_asymmetric_messages") do (topic: string, privateKey: string) -> seq[WakuMessageRPC]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called. Decrypts the message payloads
    ## before returning.
    debug "get_waku_v2_private_v1_asymmetric_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "not subscribed to topic: " & topic)

    let msgs = msgRes.get()

    let key = some(privateKey.toPrivateKey())
    return msgs.mapIt(it.toWakuMessageRPC(privateKey=key))
