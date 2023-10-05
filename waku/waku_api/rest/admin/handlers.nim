when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/strformat,
  std/sequtils,
  stew/byteutils,
  chronicles,
  json_serialization,
  presto/route,
  libp2p/[peerinfo, switch]

import
  ../../../waku_core,
  ../../../waku_store,
  ../../../waku_filter,
  ../../../waku_relay,
  ../../../waku_node,
  ../../../node/peer_manager,
  ../responses,
  ../serdes,
  ./types

export types

logScope:
  topics = "waku node rest admin api"

const ROUTE_ADMIN_V1_PEERS* = "/admin/v1/peers"

type PeerProtocolTuple = tuple[multiaddr: string, protocol: string, connected: bool]

func decodeRequestBody[T](contentBody: Option[ContentBody]) : Result[T, RestApiResponse] =
  if contentBody.isNone():
    return err(RestApiResponse.badRequest("Missing content body"))

  let reqBodyContentType = MediaType.init($contentBody.get().contentType)
  if reqBodyContentType != MIMETYPE_JSON:
    return err(RestApiResponse.badRequest("Wrong Content-Type, expected application/json"))

  let reqBodyData = contentBody.get().data

  let requestResult = decodeFromJsonBytes(T, reqBodyData)
  if requestResult.isErr():
    return err(RestApiResponse.badRequest("Invalid content body, could not decode. " &
                                          $requestResult.error))

  return ok(requestResult.get())

proc tuplesToWakuPeers(peers: var WakuPeers, peersTup: seq[PeerProtocolTuple]) =
  for peer in peersTup:
    peers.add(peer.multiaddr, peer.protocol, peer.connected)


proc installAdminV1GetPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_ADMIN_V1_PEERS) do () -> RestApiResponse:
    var peers:  WakuPeers = @[]

    if not node.wakuRelay.isNil():
      # Map managed peers to WakuPeers and add to return list
      let relayPeers = node.peerManager
                            .peerStore.peers(WakuRelayCodec)
                            .mapIt((
                                    multiaddr: constructMultiaddrStr(it),
                                    protocol: WakuRelayCodec,
                                    connected: it.connectedness == Connectedness.Connected)
                                  )
      tuplesToWakuPeers(peers, relayPeers)

    if not node.wakuFilterLegacy.isNil():
      # Map WakuFilter peers to WakuPeers and add to return list
      let filterPeers = node.peerManager.peerStore.peers(WakuLegacyFilterCodec)
          .mapIt((multiaddr: constructMultiaddrStr(it),
                  protocol: WakuLegacyFilterCodec,
                  connected: it.connectedness == Connectedness.Connected))
      tuplesToWakuPeers(peers, filterPeers)

    if not node.wakuStore.isNil():
      # Map WakuStore peers to WakuPeers and add to return list
      let storePeers = node.peerManager.peerStore
                           .peers(WakuStoreCodec)
                           .mapIt((multiaddr: constructMultiaddrStr(it),
                                   protocol: WakuStoreCodec,
                                   connected: it.connectedness == Connectedness.Connected))
      tuplesToWakuPeers(peers, storePeers)

    let resp = RestApiResponse.jsonResponse(peers, status=Http200)
    if resp.isErr():
      error "An error ocurred while building the json respose: ", error=resp.error
      return RestApiResponse.internalServerError(fmt("An error ocurred while building the json respose: {resp.error}"))

    return resp.get()

proc installAdminV1PostPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodPost, ROUTE_ADMIN_V1_PEERS) do (contentBody: Option[ContentBody]) -> RestApiResponse:

    let peers: seq[string] = decodeRequestBody[seq[string]](contentBody).valueOr:
      return RestApiResponse.badRequest(fmt("Failed to decode request: {error}"))

    for i, peer in peers:
      let peerInfo = parsePeerInfo(peer).valueOr:
        return RestApiResponse.badRequest(fmt("Couldn't parse remote peer info: {error}"))

      if not (await node.peerManager.connectRelay(peerInfo, source="rest")):
        return RestApiResponse.badRequest(fmt("Failed to connect to peer at index: {i} - {peer}"))

    return RestApiResponse.ok()

proc installAdminApiHandlers*(router: var RestRouter, node: WakuNode) =
  installAdminV1GetPeersHandler(router, node)
  installAdminV1PostPeersHandler(router, node)
