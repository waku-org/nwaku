{.push raises: [Defect, CatchableError].}

import
  std/[tables,sequtils],
  chronicles,
  json_rpc/rpcserver,
  nimcrypto/sysrand,
  ../wakunode2,
  ../waku_payload,
  ./jsonrpc_types,
  ./jsonrpc_utils

export waku_payload, jsonrpc_types

logScope:
  topics = "private api"

const futTimeout* = 5.seconds # Max time to wait for futures

proc installPrivateApiHandlers*(node: WakuNode, rpcsrv: RpcServer, rng: ref BrHmacDrbgContext, topicCache: TopicCache) =

  ## Private API version 1 definitions

  ## Definitions for symmetric cryptography
  
  rpcsrv.rpc("get_waku_v2_private_v1_symmetric_key") do() -> SymKey:
    ## Generates and returns a symmetric key for message encryption and decryption
    debug "get_waku_v2_private_v1_symmetric_key"

    var key: SymKey
    if randomBytes(key) != key.len:
      raise newException(ValueError, "Failed generating key")

    return key

  rpcsrv.rpc("post_waku_v2_private_v1_symmetric_message") do(topic: string, message: WakuRelayMessage, symkey: string) -> bool:
    ## Publishes and encrypts a message to be relayed on a PubSub topic
    debug "post_waku_v2_private_v1_symmetric_message"

    let msg = message.toWakuMessage(version = 1,
                                    rng = rng,
                                    pubKey = none(waku_payload.PublicKey),
                                    symkey =  some(symkey.toSymKey()))

    if (await node.publish(topic, msg).withTimeout(futTimeout)):
      # Successfully published message
      return true
    else:
      # Failed to publish message to topic
      raise newException(ValueError, "Failed to publish to topic " & topic)

  rpcsrv.rpc("get_waku_v2_private_v1_symmetric_messages") do(topic: string, symkey: string) -> seq[WakuRelayMessage]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called. Decrypts the message payloads
    ## before returning.
    ## 
    ## @TODO ability to specify a return message limit
    debug "get_waku_v2_private_v1_symmetric_messages", topic=topic

    if topicCache.hasKey(topic):
      let msgs = topicCache[topic]
      # Clear cache before next call
      topicCache[topic] = @[]
      return msgs.mapIt(it.toWakuRelayMessage(symkey = some(symkey.toSymKey()),
                                              privateKey = none(waku_payload.PrivateKey)))
    else:
      # Not subscribed to this topic
      raise newException(ValueError, "Not subscribed to topic: " & topic)

  ## Definitions for asymmetric cryptography
  
  rpcsrv.rpc("get_waku_v2_private_v1_asymmetric_keypair") do() -> WakuKeyPair:
    ## Generates and returns a public/private key pair for asymmetric message encryption and decryption.
    debug "get_waku_v2_private_v1_asymmetric_keypair"

    let privKey = waku_payload.PrivateKey.random(rng[])

    return WakuKeyPair(seckey: privKey, pubkey: privKey.toPublicKey())

  rpcsrv.rpc("post_waku_v2_private_v1_asymmetric_message") do(topic: string, message: WakuRelayMessage, publicKey: string) -> bool:
    ## Publishes and encrypts a message to be relayed on a PubSub topic
    debug "post_waku_v2_private_v1_asymmetric_message"

    let msg = message.toWakuMessage(version = 1,
                                    rng = rng,
                                    symkey = none(SymKey),
                                    pubKey = some(publicKey.toPublicKey()))

    if (await node.publish(topic, msg).withTimeout(futTimeout)):
      # Successfully published message
      return true
    else:
      # Failed to publish message to topic
      raise newException(ValueError, "Failed to publish to topic " & topic)

  rpcsrv.rpc("get_waku_v2_private_v1_asymmetric_messages") do(topic: string, privateKey: string) -> seq[WakuRelayMessage]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called. Decrypts the message payloads
    ## before returning.
    ## 
    ## @TODO ability to specify a return message limit
    debug "get_waku_v2_private_v1_asymmetric_messages", topic=topic

    if topicCache.hasKey(topic):
      let msgs = topicCache[topic]
      # Clear cache before next call
      topicCache[topic] = @[]
      return msgs.mapIt(it.toWakuRelayMessage(symkey = none(SymKey), privateKey = some(privateKey.toPrivateKey())))
    else:
      # Not subscribed to this topic
      raise newException(ValueError, "Not subscribed to topic: " & topic)
