{.push raises: [].}

import
  std/[sets, strformat, sequtils, tables],
  chronicles,
  json_serialization,
  presto/route,
  libp2p/[peerinfo, switch, peerid, protocols/pubsub/pubsubpeer]

import
  waku/[
    waku_core,
    waku_core/topics/pubsub_topic,
    waku_store_legacy/common,
    waku_store/common,
    waku_filter_v2,
    waku_lightpush_legacy/common,
    waku_relay,
    waku_peer_exchange,
    waku_node,
    node/peer_manager,
    waku_enr/sharding,
  ],
  ../responses,
  ../serdes,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest admin api"

const ROUTE_ADMIN_V1_PEERS* = "/admin/v1/peers" # returns all peers
const ROUTE_ADMIN_V1_SINGLE_PEER* = "/admin/v1/peer/{peerId}"

const ROUTE_ADMIN_V1_CONNECTED_PEERS* = "/admin/v1/peers/connected"
const ROUTE_ADMIN_V1_CONNECTED_PEERS_ON_SHARD* =
  "/admin/v1/peers/connected/on/{shardId}"
const ROUTE_ADMIN_V1_CONNECTED_RELAY_PEERS* = "/admin/v1/peers/connected/relay"
const ROUTE_ADMIN_V1_CONNECTED_RELAY_PEERS_ON_SHARD* =
  "/admin/v1/peers/connected/relay/on/{shardId}"
const ROUTE_ADMIN_V1_MESH_PEERS* = "/admin/v1/peers/mesh"
const ROUTE_ADMIN_V1_MESH_PEERS_ON_SHARD* = "/admin/v1/peers/mesh/on/{shardId}"

const ROUTE_ADMIN_V1_FILTER_SUBS* = "/admin/v1/filter/subscriptions"

type PeerProtocolTuple =
  tuple[
    multiaddr: string,
    protocol: string,
    shards: seq[uint16],
    connected: Connectedness,
    agent: string,
    origin: PeerOrigin,
  ]

proc tuplesToWakuPeers(peers: var WakuPeers, peersTup: seq[PeerProtocolTuple]) =
  for peer in peersTup:
    peers.add(
      peer.multiaddr, peer.protocol, peer.shards, peer.connected, peer.agent,
      peer.origin,
    )

proc populateAdminPeerInfo(peers: var WakuPeers, node: WakuNode, codec: string) =
  let peersForCodec = node.peerManager.switch.peerStore.peers(codec).mapIt(
      (
        multiaddr: constructMultiaddrStr(it),
        protocol: codec,
        shards: it.getShards(),
        connected: it.connectedness,
        agent: it.agent,
        origin: it.origin,
      )
    )
  tuplesToWakuPeers(peers, peersForCodec)

proc installAdminV1GetPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_ADMIN_V1_PEERS) do() -> RestApiResponse:
    var peers: WakuPeers = @[]

    populateAdminPeerInfo(peers, node, WakuRelayCodec)
    populateAdminPeerInfo(peers, node, WakuFilterSubscribeCodec)
    populateAdminPeerInfo(peers, node, WakuStoreCodec)
    populateAdminPeerInfo(peers, node, WakuLegacyStoreCodec)
    populateAdminPeerInfo(peers, node, WakuLegacyLightPushCodec)
    populateAdminPeerInfo(peers, node, WakuLightPushCodec)
    populateAdminPeerInfo(peers, node, WakuPeerExchangeCodec)
    populateAdminPeerInfo(peers, node, WakuReconciliationCodec)

    let resp = RestApiResponse.jsonResponse(peers, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

  router.api(MethodGet, ROUTE_ADMIN_V1_SINGLE_PEER) do(
    peerId: string
  ) -> RestApiResponse:
    let peerIdString = peerId.valueOr:
      return RestApiResponse.badRequest("Invalid argument:" & $error)

    let peerIdVal: PeerId = PeerId.init(peerIdString).valueOr:
      return RestApiResponse.badRequest("Invalid argument:" & $error)

    if node.peerManager.switch.peerStore.peerExists(peerIdVal):
      let peerInfo = node.peerManager.switch.peerStore.getPeer(peerIdVal)
      let peer = WakuPeer.init(peerInfo)
      let resp = RestApiResponse.jsonResponse(peer, status = Http200)
      if resp.isErr():
        error "An error occurred while building the json response: ", error = resp.error
        return RestApiResponse.internalServerError(
          fmt("An error occurred while building the json response: {resp.error}")
        )

      return resp.get()
    else:
      return RestApiResponse.notFound(fmt("Peer with ID {peerId} not found"))

  router.api(MethodGet, ROUTE_ADMIN_V1_CONNECTED_PEERS) do() -> RestApiResponse:
    var allPeers: WakuPeers = @[]

    populateAdminPeerInfo(allPeers, node, WakuRelayCodec)
    populateAdminPeerInfo(allPeers, node, WakuFilterSubscribeCodec)
    populateAdminPeerInfo(allPeers, node, WakuStoreCodec)
    populateAdminPeerInfo(allPeers, node, WakuLegacyStoreCodec)
    populateAdminPeerInfo(allPeers, node, WakuLegacyLightPushCodec)
    populateAdminPeerInfo(allPeers, node, WakuLightPushCodec)
    populateAdminPeerInfo(allPeers, node, WakuPeerExchangeCodec)
    populateAdminPeerInfo(allPeers, node, WakuReconciliationCodec)

    let connectedPeers = allPeers.filterIt(it.connected == Connectedness.Connected)

    let resp = RestApiResponse.jsonResponse(connectedPeers, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

  router.api(MethodGet, ROUTE_ADMIN_V1_CONNECTED_PEERS_ON_SHARD) do(
    shardId: uint16
  ) -> RestApiResponse:
    let shard = shardId.valueOr:
      return RestApiResponse.badRequest(fmt("Invalid shardId: {error}"))

    var allPeers: WakuPeers = @[]
    populateAdminPeerInfo(allPeers, node, WakuRelayCodec)
    populateAdminPeerInfo(allPeers, node, WakuFilterSubscribeCodec)
    populateAdminPeerInfo(allPeers, node, WakuStoreCodec)
    populateAdminPeerInfo(allPeers, node, WakuLegacyStoreCodec)
    populateAdminPeerInfo(allPeers, node, WakuLegacyLightPushCodec)
    populateAdminPeerInfo(allPeers, node, WakuLightPushCodec)
    populateAdminPeerInfo(allPeers, node, WakuPeerExchangeCodec)
    populateAdminPeerInfo(allPeers, node, WakuReconciliationCodec)

    let connectedPeers = allPeers.filterIt(
      it.connected == Connectedness.Connected and it.shards.contains(shard)
    )

    let resp = RestApiResponse.jsonResponse(connectedPeers, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

  router.api(MethodGet, ROUTE_ADMIN_V1_CONNECTED_RELAY_PEERS) do() -> RestApiResponse:
    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    var relayPeers: PeersOfShards = @[]
    for topic in node.wakuRelay.getSubscribedTopics():
      let relayShard = RelayShard.parse(topic).valueOr:
        error "Invalid subscribed topic", error = error, topic = topic
        continue
      let pubsubPeers =
        node.wakuRelay.getConnectedPubSubPeers(topic).get(initHashSet[PubSubPeer](0))
      relayPeers.add(
        PeersOfShard(
          shard: relayShard.shardId,
          peers: toSeq(pubsubPeers).mapIt(WakuPeer.init(it, node.peerManager)),
        )
      )

    let resp = RestApiResponse.jsonResponse(relayPeers, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

  router.api(MethodGet, ROUTE_ADMIN_V1_CONNECTED_RELAY_PEERS_ON_SHARD) do(
    shardId: uint16
  ) -> RestApiResponse:
    let shard = shardId.valueOr:
      return RestApiResponse.badRequest(fmt("Invalid shardId: {error}"))

    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    let topic =
      toPubsubTopic(RelayShard(clusterId: node.wakuSharding.clusterId, shardId: shard))
    let pubsubPeers =
      node.wakuRelay.getConnectedPubSubPeers(topic).get(initHashSet[PubSubPeer](0))
    let relayPeer = PeersOfShard(
      shard: shard, peers: toSeq(pubsubPeers).mapIt(WakuPeer.init(it, node.peerManager))
    )

    let resp = RestApiResponse.jsonResponse(relayPeer, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

  router.api(MethodGet, ROUTE_ADMIN_V1_MESH_PEERS) do() -> RestApiResponse:
    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    var relayPeers: PeersOfShards = @[]
    for topic in node.wakuRelay.getSubscribedTopics():
      let relayShard = RelayShard.parse(topic).valueOr:
        error "Invalid subscribed topic", error = error, topic = topic
        continue
      let peers =
        node.wakuRelay.getPubSubPeersInMesh(topic).get(initHashSet[PubSubPeer](0))
      relayPeers.add(
        PeersOfShard(
          shard: relayShard.shardId,
          peers: toSeq(peers).mapIt(WakuPeer.init(it, node.peerManager)),
        )
      )

    let resp = RestApiResponse.jsonResponse(relayPeers, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

  router.api(MethodGet, ROUTE_ADMIN_V1_MESH_PEERS_ON_SHARD) do(
    shardId: uint16
  ) -> RestApiResponse:
    let shard = shardId.valueOr:
      return RestApiResponse.badRequest(fmt("Invalid shardId: {error}"))

    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    let topic =
      toPubsubTopic(RelayShard(clusterId: node.wakuSharding.clusterId, shardId: shard))
    let peers =
      node.wakuRelay.getPubSubPeersInMesh(topic).get(initHashSet[PubSubPeer](0))
    let relayPeer = PeersOfShard(
      shard: shard, peers: toSeq(peers).mapIt(WakuPeer.init(it, node.peerManager))
    )

    let resp = RestApiResponse.jsonResponse(relayPeer, status = Http200)
    if resp.isErr():
      error "An error occurred while building the json response: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {resp.error}")
      )

    return resp.get()

proc installAdminV1PostPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodPost, ROUTE_ADMIN_V1_PEERS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    let peers: seq[string] = decodeRequestBody[seq[string]](contentBody).valueOr:
      let e = $error
      return RestApiResponse.badRequest(fmt("Failed to decode request: {e}"))

    for i, peer in peers:
      let peerInfo = parsePeerInfo(peer).valueOr:
        let e = $error
        return RestApiResponse.badRequest(fmt("Couldn't parse remote peer info: {e}"))

      if not (await node.peerManager.connectPeer(peerInfo, source = "rest")):
        return RestApiResponse.badRequest(
          fmt("Failed to connect to peer at index: {i} - {peer}")
        )

    return RestApiResponse.ok()

proc installAdminV1GetFilterSubsHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_ADMIN_V1_FILTER_SUBS) do() -> RestApiResponse:
    if node.wakuFilter.isNil():
      return
        RestApiResponse.badRequest("Error: Filter Protocol is not mounted to the node")

    var
      subscriptions: seq[FilterSubscription] = @[]
      filterCriteria: seq[FilterTopic]

    for peerId in node.wakuFilter.subscriptions.peersSubscribed.keys:
      filterCriteria = node.wakuFilter.subscriptions.getPeerSubscriptions(peerId).mapIt(
          FilterTopic(pubsubTopic: it[0], contentTopic: it[1])
        )

      subscriptions.add(
        FilterSubscription(peerId: $peerId, filterCriteria: filterCriteria)
      )

    let resp = RestApiResponse.jsonResponse(subscriptions, status = Http200)
    if resp.isErr():
      error "An error ocurred while building the json respose: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error ocurred while building the json respose: {resp.error}")
      )

    return resp.get()

proc installAdminApiHandlers*(router: var RestRouter, node: WakuNode) =
  installAdminV1GetPeersHandler(router, node)
  installAdminV1PostPeersHandler(router, node)
  installAdminV1GetFilterSubsHandler(router, node)
