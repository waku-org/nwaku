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
  ../../../../waku/v2/protocol/waku_message,
  ../../../../waku/v2/protocol/waku_relay,
  ../../../../waku/v2/node/waku_node,
  ../../../../waku/v2/node/message_cache,
  ../../../../waku/v2/utils/compat,
  ../../../../waku/v2/utils/time,
  ../hexstrings,
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


  server.rpc("post_waku_v2_relay_v1_subscriptions") do (topics: seq[string]) -> bool:
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"

    # Subscribe to all requested topics
    for topic in topics:
      if cache.isSubscribed(topic):
        continue

      cache.subscribe(topic)
      node.subscribe(topic, topicHandler)

    return true

  server.rpc("delete_waku_v2_relay_v1_subscriptions") do (topics: seq[string]) -> bool:
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"

    # Unsubscribe all handlers from requested topics
    for topic in topics:
      node.unsubscribeAll(topic)
      cache.unsubscribe(topic)

    return true

  server.rpc("post_waku_v2_relay_v1_message") do (topic: string, msg: WakuRelayMessage) -> bool:
    ## Publishes a WakuMessage to a PubSub topic
    debug "post_waku_v2_relay_v1_message"

    let message = block:
        WakuMessage(
          payload: msg.payload,
          # TODO: Fail if the message doesn't have a content topic
          contentTopic: msg.contentTopic.get(DefaultContentTopic),
          version: 0,
          timestamp: msg.timestamp.get(Timestamp(0))
        )

    let publishFut = node.publish(topic, message)

    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to publish to topic " & topic)

    return true

  server.rpc("get_waku_v2_relay_v1_messages") do (topic: string) -> seq[WakuMessage]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called
    debug "get_waku_v2_relay_v1_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    return msgRes.value


## Waku Relay Private JSON-RPC API (Whisper/Waku v1 compatibility)

proc toWakuMessage(relayMessage: WakuRelayMessage, version: uint32, rng: ref HmacDrbgContext, symkey: Option[SymKey], pubKey: Option[keys.PublicKey]): WakuMessage =
  let payload = Payload(payload: relayMessage.payload,
                        dst: pubKey,
                        symkey: symkey)

  var t: Timestamp
  if relayMessage.timestamp.isSome:
    t = relayMessage.timestamp.get
  else:
    # incoming WakuRelayMessages with no timestamp will get 0 timestamp
    t = Timestamp(0)

  WakuMessage(payload: payload.encode(version, rng[]).get(),
              contentTopic: relayMessage.contentTopic.get(DefaultContentTopic),
              version: version,
              timestamp: t)

proc toWakuRelayMessage(message: WakuMessage, symkey: Option[SymKey], privateKey: Option[keys.PrivateKey]): WakuRelayMessage =
  let
    keyInfo = if symkey.isSome(): KeyInfo(kind: Symmetric, symKey: symkey.get())
              elif privateKey.isSome(): KeyInfo(kind: Asymmetric, privKey: privateKey.get())
              else: KeyInfo(kind: KeyKind.None)
    decoded = decodePayload(message, keyInfo)

  WakuRelayMessage(payload: decoded.get().payload,
                   contentTopic: some(message.contentTopic),
                   timestamp: some(message.timestamp))


proc installRelayPrivateApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache) =

  server.rpc("get_waku_v2_private_v1_symmetric_key") do () -> SymKey:
    ## Generates and returns a symmetric key for message encryption and decryption
    debug "get_waku_v2_private_v1_symmetric_key"

    var key: SymKey
    if randomBytes(key) != key.len:
      raise newException(ValueError, "Failed generating key")

    return key

  server.rpc("post_waku_v2_private_v1_symmetric_message") do (topic: string, message: WakuRelayMessage, symkey: string) -> bool:
    ## Publishes and encrypts a message to be relayed on a PubSub topic
    debug "post_waku_v2_private_v1_symmetric_message"

    let msg = message.toWakuMessage(version = 1,
                                    rng = node.rng,
                                    pubKey = none(keys.PublicKey),
                                    symkey =  some(symkey.toSymKey()))

    if (await node.publish(topic, msg).withTimeout(futTimeout)):
      # Successfully published message
      return true
    else:
      # Failed to publish message to topic
      raise newException(ValueError, "Failed to publish to topic " & topic)

  server.rpc("get_waku_v2_private_v1_symmetric_messages") do (topic: string, symkey: string) -> seq[WakuRelayMessage]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called. Decrypts the message payloads
    ## before returning.
    debug "get_waku_v2_private_v1_symmetric_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgs = msgRes.get()

    return msgs.mapIt(it.toWakuRelayMessage(symkey=some(symkey.toSymKey()),
                                            privateKey=none(keys.PrivateKey)))

  server.rpc("get_waku_v2_private_v1_asymmetric_keypair") do () -> WakuKeyPair:
    ## Generates and returns a public/private key pair for asymmetric message encryption and decryption.
    debug "get_waku_v2_private_v1_asymmetric_keypair"

    let privKey = keys.PrivateKey.random(node.rng[])

    return WakuKeyPair(seckey: privKey, pubkey: privKey.toPublicKey())

  server.rpc("post_waku_v2_private_v1_asymmetric_message") do (topic: string, message: WakuRelayMessage, publicKey: string) -> bool:
    ## Publishes and encrypts a message to be relayed on a PubSub topic
    debug "post_waku_v2_private_v1_asymmetric_message"

    let msg = message.toWakuMessage(version = 1,
                                    rng = node.rng,
                                    symkey = none(SymKey),
                                    pubKey = some(publicKey.toPublicKey()))

    let publishFut = node.publish(topic, msg)
    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to publish to topic " & topic)

    return true

  server.rpc("get_waku_v2_private_v1_asymmetric_messages") do (topic: string, privateKey: string) -> seq[WakuRelayMessage]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called. Decrypts the message payloads
    ## before returning.
    debug "get_waku_v2_private_v1_asymmetric_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgs = msgRes.get()
    return msgs.mapIt(it.toWakuRelayMessage(symkey=none(SymKey),
                                            privateKey=some(privateKey.toPrivateKey())))
