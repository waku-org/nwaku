when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strformat, sequtils, sets, tables],
  stew/byteutils,
  chronicles,
  json_serialization,
  presto/route,
  libp2p/[peerinfo, switch]

import
  ../../../waku_core,
  ../../../waku_store,
  ../../../waku_filter_v2,
  ../../../waku_lightpush/common,
  ../../../waku_relay,
  ../../../waku_node,
  ../../../node/peer_manager,
  ../responses,
  ../serdes,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest admin api"

const ROUTE_ADMIN_V1_PEERS* = "/admin/v1/peers"
const ROUTE_ADMIN_V1_FILTER_SUBS* = "/admin/v1/filter/subscriptions"

type PeerProtocolTuple = tuple[multiaddr: string, protocol: string, connected: bool]

proc tuplesToWakuPeers(peers: var WakuPeers, peersTup: seq[PeerProtocolTuple]) =
  for peer in peersTup:
    peers.add(peer.multiaddr, peer.protocol, peer.connected)

proc installAdminV1GetPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_ADMIN_V1_PEERS) do() -> RestApiResponse:
    var peers: WakuPeers = @[]

    if not node.wakuRelay.isNil():
      # Map managed peers to WakuPeers and add to return list
      let relayPeers = node.peerManager.peerStore.peers(WakuRelayCodec).mapIt(
          (
            multiaddr: constructMultiaddrStr(it),
            protocol: WakuRelayCodec,
            connected: it.connectedness == Connectedness.Connected,
          )
        )
      tuplesToWakuPeers(peers, relayPeers)

    if not node.wakuFilter.isNil():
      # Map WakuFilter peers to WakuPeers and add to return list
      let filterV2Peers = node.peerManager.peerStore
        .peers(WakuFilterSubscribeCodec)
        .mapIt(
          (
            multiaddr: constructMultiaddrStr(it),
            protocol: WakuFilterSubscribeCodec,
            connected: it.connectedness == Connectedness.Connected,
          )
        )
      tuplesToWakuPeers(peers, filterV2Peers)

    if not node.wakuStore.isNil():
      # Map WakuStore peers to WakuPeers and add to return list
      let storePeers = node.peerManager.peerStore.peers(WakuStoreCodec).mapIt(
          (
            multiaddr: constructMultiaddrStr(it),
            protocol: WakuStoreCodec,
            connected: it.connectedness == Connectedness.Connected,
          )
        )
      tuplesToWakuPeers(peers, storePeers)

    if not node.wakuLightPush.isNil():
      # Map WakuStore peers to WakuPeers and add to return list
      let lightpushPeers = node.peerManager.peerStore.peers(WakuLightPushCodec).mapIt(
          (
            multiaddr: constructMultiaddrStr(it),
            protocol: WakuLightPushCodec,
            connected: it.connectedness == Connectedness.Connected,
          )
        )
      tuplesToWakuPeers(peers, lightpushPeers)

    let resp = RestApiResponse.jsonResponse(peers, status = Http200)
    if resp.isErr():
      error "An error ocurred while building the json respose: ", error = resp.error
      return RestApiResponse.internalServerError(
        fmt("An error ocurred while building the json respose: {resp.error}")
      )

    return resp.get()

proc installAdminV1PostPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodPost, ROUTE_ADMIN_V1_PEERS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    let peers: seq[string] = decodeRequestBody[seq[string]](contentBody).valueOr:
      return RestApiResponse.badRequest(fmt("Failed to decode request: {error}"))

    for i, peer in peers:
      let peerInfo = parsePeerInfo(peer).valueOr:
        return
          RestApiResponse.badRequest(fmt("Couldn't parse remote peer info: {error}"))

      if not (await node.peerManager.connectRelay(peerInfo, source = "rest")):
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
