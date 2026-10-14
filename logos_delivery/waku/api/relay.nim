## Waku layer API — relay (gossipsub) operations.
{.push raises: [].}

import std/sequtils
import results, chronos, chronicles, secp256k1, stew/byteutils

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/waku_node/relay,
    node/subscription_manager,
    waku_relay/protocol,
    factory/waku_conf,
    factory/validator_signed,
  ]

proc relayPublish*(
    self: Kernel, pubsubTopic: PubsubTopic, message: WakuMessage, timeoutMs: uint32
): Future[Result[string, string]] {.async.} =
  ## Publishes `message` and returns its message hash (0x-hex).
  try:
    if self.protocols.relay.isNil():
      return err("relayPublish: WakuRelay not mounted")

    (await self.protocols.relay.publish(pubsubTopic, message)).isOkOr:
      return err($error)

    return ok(computeMessageHash(pubsubTopic, message).to0xHex)
  except CatchableError as e:
    return err(e.msg)

proc relaySubscribe*(
    self: Kernel,
    pubsubTopic: PubsubTopic,
    handler: WakuRelayHandler = WakuRelayHandler(nil),
): Future[Result[bool, string]] {.async.} =
  ## Subscribes to `pubsubTopic`. `handler` (optional) is invoked per message;
  ## pass nil to subscribe without a message callback.
  try:
    if self.protocols.relay.isNil():
      return err("relaySubscribe: WakuRelay not mounted")

    self.subscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic), handler).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayUnsubscribe*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayUnsubscribe: WakuRelay not mounted")

    self.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic)).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayAddProtectedShard*(
    self: Kernel, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[bool, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayAddProtectedShard: WakuRelay not mounted")

    let pubKey = SkPublicKey.fromHex(publicKey).valueOr:
      return err("relayAddProtectedShard: invalid public key: " & $error)

    let protectedShard = ProtectedShard(shard: shardId, key: pubKey)
    self.protocols.relay.addSignedShardsValidator(@[protectedShard], clusterId)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayConnectedPeers*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayConnectedPeers: WakuRelay not mounted")

    let connPeers = self.protocols.relay.getConnectedPeers(pubsubTopic).valueOr:
      return err($error)

    return ok(connPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayPeersInMesh*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayPeersInMesh: WakuRelay not mounted")

    let meshPeers = self.protocols.relay.getPeersInMesh(pubsubTopic).valueOr:
      return err($error)

    return ok(meshPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayNumPeersInMesh*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[int, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayNumPeersInMesh: WakuRelay not mounted")
    let n = self.protocols.relay.getNumPeersInMesh(pubsubTopic).valueOr:
      return err($error)
    return ok(n)
  except CatchableError as e:
    return err(e.msg)

proc relayNumConnectedPeers*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[int, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayNumConnectedPeers: WakuRelay not mounted")
    let n = self.protocols.relay.getNumConnectedPeers(pubsubTopic).valueOr:
      return err($error)
    return ok(n)
  except CatchableError as e:
    return err(e.msg)
