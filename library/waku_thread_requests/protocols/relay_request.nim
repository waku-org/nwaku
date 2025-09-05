import std/[net, sequtils, strutils, json], strformat
import chronicles, chronos, stew/byteutils, results, ffi
import
  ../../../waku/waku_core/message/message,
  ../../../waku/factory/[external_config, validator_signed, waku],
  ../../../waku/waku_node,
  ../../../waku/waku_core/message,
  ../../../waku/waku_core/time, # Timestamp
  ../../../waku/waku_core/topics/pubsub_topic,
  ../../../waku/waku_core/topics,
  ../../../waku/waku_relay/protocol,
  ../../../waku/node/peer_manager,
  ../../events/json_message_event

registerReqFFI(GetPeersInMeshReq, waku: ptr Waku):
  proc(pubSubTopic: cstring): Future[Result[string, string]] {.async.} =
    let meshPeers = waku.node.wakuRelay.getPeersInMesh($pubsubTopic).valueOr:
      error "LIST_MESH_PEERS failed", error = error
      return err($error)
    ## returns a comma-separated string of peerIDs
    return ok(meshPeers.mapIt($it).join(","))

registerReqFFI(GetNumPeersInMeshReq, waku: ptr Waku):
  proc(pubSubTopic: cstring): Future[Result[string, string]] {.async.} =
    let numPeersInMesh = waku.node.wakuRelay.getNumPeersInMesh($pubsubTopic).valueOr:
      error "NUM_MESH_PEERS failed", error = error
      return err($error)
    return ok($numPeersInMesh)

registerReqFFI(GetConnectedPeersReq, waku: ptr Waku):
  proc(pubSubTopic: cstring): Future[Result[string, string]] {.async.} =
    ## Returns the list of all connected peers to an specific pubsub topic
    let connPeers = waku.node.wakuRelay.getConnectedPeers($pubsubTopic).valueOr:
      error "LIST_CONNECTED_PEERS failed", error = error
      return err($error)
    ## returns a comma-separated string of peerIDs
    return ok(connPeers.mapIt($it).join(","))

registerReqFFI(GetNumConnectedPeersReq, waku: ptr Waku):
  proc(pubSubTopic: cstring): Future[Result[string, string]] {.async.} =
    let numConnPeers = waku.node.wakuRelay.getNumConnectedPeers($pubsubTopic).valueOr:
      error "NUM_CONNECTED_PEERS failed", error = error
      return err($error)
    return ok($numConnPeers)

registerReqFFI(AddProtectedShardReq, waku: ptr Waku):
  proc(
      clusterId: cint, shardId: cint, publicKey: cstring
  ): Future[Result[string, string]] {.async.} =
    ## Protects a shard with a public key
    try:
      let relayShard =
        RelayShard(clusterId: uint16(clusterId), shardId: uint16(shardId))
      let protectedShard = ProtectedShard.parseCmdArg($relayShard & ":" & $publicKey)
      waku.node.wakuRelay.addSignedShardsValidator(@[protectedShard], uint16(clusterId))
    except ValueError as exc:
      return err("ERROR in AddProtectedShardReq: " & exc.msg)

    return ok("")

registerReqFFI(SubscribeReq, waku: ptr Waku):
  proc(
      pubSubTopic: cstring, relayEventCallback: WakuRelayHandler
  ): Future[Result[string, string]] {.async.} =
    waku.node.subscribe(
      (kind: SubscriptionKind.PubsubSub, topic: $pubsubTopic),
      handler = relayEventCallback,
    ).isOkOr:
      error "SUBSCRIBE failed", error = error
      return err($error)
    return ok("")

registerReqFFI(UnsubscribeReq, waku: ptr Waku):
  proc(pubSubTopic: cstring): Future[Result[string, string]] {.async.} =
    waku.node.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: $pubsubTopic)).isOkOr:
      error "UNSUBSCRIBE failed", error = error
      return err($error)

    return ok("")

registerReqFFI(PublishRelayMsgReq, waku: ptr Waku):
  proc(
      pubSubTopic: cstring, jsonWakuMessage: cstring, timeoutMs: cuint
  ): Future[Result[string, string]] {.async.} =
    var jsonMessage: JsonMessage
    try:
      let jsonContent = parseJson($jsonWakuMessage)
      jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
        raise newException(JsonParsingError, $error)
    except JsonParsingError as exc:
      return err(fmt"Error parsing json message: {exc.msg}")

    let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
      return err("Problem building the WakuMessage: " & $error)

    (await waku.node.wakuRelay.publish($pubsubTopic, msg)).isOkOr:
      error "PUBLISH failed", error = error
      return err($error)

    let msgHash = computeMessageHash($pubSubTopic, msg).to0xHex
    return ok(msgHash)

registerReqFFI(FetchPubsubTopicRequest, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    return ok(DefaultPubsubTopic)

registerReqFFI(BuildContentTopicReq, waku: ptr Waku):
  proc(
      appName: cstring, appVersion: cuint, contentTopicName: cstring, encoding: cstring
  ): Future[Result[string, string]] {.async.} =
    return ok(fmt"/{$appName}/{$appVersion}/{$contentTopicName}/{$encoding}")

registerReqFFI(BuildPubsubTopicReq, waku: ptr Waku):
  proc(topicName: cstring): Future[Result[string, string]] {.async.} =
    return ok(fmt"/waku/2/{$topicName}")
