{.push raises: [].}

import
  std/[options, tables, strutils, sequtils, os, net, random],
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  nimcrypto,
  bearssl/rand,
  stew/byteutils,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/[multiaddress, multicodec],
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utility,
  libp2p/protocols/mix,
  libp2p/protocols/mix/mix_protocol

import
  ../waku_core,
  ../waku_core/topics/sharding,
  ../waku_relay,
  ../waku_archive,
  ../waku_archive_legacy,
  ../waku_store_legacy/protocol as legacy_store,
  ../waku_store_legacy/client as legacy_store_client,
  ../waku_store_legacy/common as legacy_store_common,
  ../waku_store/protocol as store,
  ../waku_store/client as store_client,
  ../waku_store/common as store_common,
  ../waku_store/resume,
  ../waku_store_sync,
  ../waku_filter_v2,
  ../waku_filter_v2/client as filter_client,
  ../waku_metadata,
  ../waku_rendezvous/protocol,
  ../waku_lightpush_legacy/client as legacy_ligntpuhs_client,
  ../waku_lightpush_legacy as legacy_lightpush_protocol,
  ../waku_lightpush/client as ligntpuhs_client,
  ../waku_lightpush as lightpush_protocol,
  ../waku_enr,
  ../waku_peer_exchange,
  ../waku_rln_relay,
  ./net_config,
  ./peer_manager,
  ../common/rate_limit/setting,
  ../common/callbacks,
  ../common/nimchronos,
  ../waku_mix

declarePublicCounter waku_node_messages, "number of messages received", ["type"]

declarePublicGauge waku_version,
  "Waku version info (in git describe format)", ["version"]
declarePublicCounter waku_node_errors, "number of wakunode errors", ["type"]
declarePublicGauge waku_lightpush_peers, "number of lightpush peers"
declarePublicGauge waku_filter_peers, "number of filter peers"
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_px_peers,
  "number of peers (in the node's peerManager) supporting the peer exchange protocol"

logScope:
  topics = "waku node"

# randomize initializes sdt/random's random number generator
# if not called, the outcome of randomization procedures will be the same in every run
randomize()

# TODO: Move to application instance (e.g., `WakuNode2`)
# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

const WakuNodeVersionString* = "version / git commit hash: " & git_version

# key and crypto modules different
type
  # TODO: Move to application instance (e.g., `WakuNode2`)
  WakuInfo* = object # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string #multiaddrStrings*: seq[string]
    mixPubKey*: Option[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuArchive*: waku_archive.WakuArchive
    wakuLegacyArchive*: waku_archive_legacy.WakuArchive
    wakuLegacyStore*: legacy_store.WakuStore
    wakuLegacyStoreClient*: legacy_store_client.WakuStoreClient
    wakuStore*: store.WakuStore
    wakuStoreClient*: store_client.WakuStoreClient
    wakuStoreResume*: StoreResume
    wakuStoreReconciliation*: SyncReconciliation
    wakuStoreTransfer*: SyncTransfer
    wakuFilter*: waku_filter_v2.WakuFilter
    wakuFilterClient*: filter_client.WakuFilterClient
    wakuRlnRelay*: WakuRLNRelay
    wakuLegacyLightPush*: WakuLegacyLightPush
    wakuLegacyLightpushClient*: WakuLegacyLightPushClient
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuPeerExchange*: WakuPeerExchange
    wakuPeerExchangeClient*: WakuPeerExchangeClient
    wakuMetadata*: WakuMetadata
    wakuAutoSharding*: Option[Sharding]
    enr*: enr.Record
    libp2pPing*: Ping
    rng*: ref rand.HmacDrbgContext
    wakuRendezvous*: WakuRendezVous
    announcedAddresses*: seq[MultiAddress]
    started*: bool # Indicates that node has started listening
    topicSubscriptionQueue*: AsyncEventQueue[SubscriptionEvent]
    rateLimitSettings*: ProtocolRateLimitSettings
    wakuMix*: WakuMix

proc getShardsGetter(node: WakuNode): GetShards =
  return proc(): seq[uint16] {.closure, gcsafe, raises: [].} =
    # fetch pubsubTopics subscribed to relay and convert them to shards
    if node.wakuRelay.isNil():
      return @[]
    let subscribedTopics = node.wakuRelay.subscribedTopics()
    let relayShards = topicsToRelayShards(subscribedTopics).valueOr:
      error "could not convert relay topics to shards",
        error = $error, topics = subscribedTopics
      return @[]
    if relayShards.isSome():
      let shards = relayShards.get().shardIds
      return shards
    return @[]

proc getCapabilitiesGetter(node: WakuNode): GetCapabilities =
  return proc(): seq[Capabilities] {.closure, gcsafe, raises: [].} =
    if node.wakuRelay.isNil():
      return @[]
    return node.enr.getCapabilities()

proc new*(
    T: type WakuNode,
    netConfig: NetConfig,
    enr: enr.Record,
    switch: Switch,
    peerManager: PeerManager,
    rateLimitSettings: ProtocolRateLimitSettings = DefaultProtocolRateLimit,
    # TODO: make this argument required after tests are updated
    rng: ref HmacDrbgContext = crypto.newRng(),
): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node instance.

  info "Initializing networking", addrs = $netConfig.announcedAddresses

  let queue = newAsyncEventQueue[SubscriptionEvent](0)
  let node = WakuNode(
    peerManager: peerManager,
    switch: switch,
    rng: rng,
    enr: enr,
    announcedAddresses: netConfig.announcedAddresses,
    topicSubscriptionQueue: queue,
    rateLimitSettings: rateLimitSettings,
  )

  peerManager.setShardGetter(node.getShardsGetter())

  return node

proc peerInfo*(node: WakuNode): PeerInfo =
  node.switch.peerInfo

proc peerId*(node: WakuNode): PeerId =
  node.peerInfo.peerId

# TODO: Move to application instance (e.g., `WakuNode2`)
# TODO: Extend with more relevant info: topics, peers, memory usage, online time, etc
proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.

  let peerInfo = node.switch.peerInfo

  var listenStr: seq[string]
  for address in node.announcedAddresses:
    var fulladdr = $address & "/p2p/" & $peerInfo.peerId
    listenStr &= fulladdr
  let enrUri = node.enr.toUri()
  var wakuInfo = WakuInfo(listenAddresses: listenStr, enrUri: enrUri)
  if not node.wakuMix.isNil():
    let keyStr = node.wakuMix.pubKey.to0xHex()
    wakuInfo.mixPubKey = some(keyStr)
  info "node info", wakuInfo
  return wakuInfo

proc connectToNodes*(
    node: WakuNode, nodes: seq[RemotePeerInfo] | seq[string], source = "api"
) {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  # NOTE Connects to the node without a give protocol, which automatically creates streams for relay
  await peer_manager.connectToNodes(node.peerManager, nodes, source = source)

proc disconnectNode*(node: WakuNode, remotePeer: RemotePeerInfo) {.async.} =
  await peer_manager.disconnectNode(node.peerManager, remotePeer)

proc mountMetadata*(
    node: WakuNode, clusterId: uint32, shards: seq[uint16]
): Result[void, string] =
  if not node.wakuMetadata.isNil():
    return err("Waku metadata already mounted, skipping")

  let metadata = WakuMetadata.new(clusterId, node.getShardsGetter())

  node.wakuMetadata = metadata
  node.peerManager.wakuMetadata = metadata

  let catchRes = catch:
    node.switch.mount(node.wakuMetadata, protocolMatcher(WakuMetadataCodec))
  if catchRes.isErr():
    return err(catchRes.error.msg)

  return ok()

## Waku AutoSharding
proc mountAutoSharding*(
    node: WakuNode, clusterId: uint16, shardCount: uint32
): Result[void, string] =
  info "mounting auto sharding", clusterId = clusterId, shardCount = shardCount
  node.wakuAutoSharding =
    some(Sharding(clusterId: clusterId, shardCountGenZero: shardCount))
  return ok()

proc getMixNodePoolSize*(node: WakuNode): int =
  return node.wakuMix.getNodePoolSize()

proc mountMix*(
    node: WakuNode,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    mixnodes: seq[MixNodePubInfo],
): Future[Result[void, string]] {.async.} =
  info "mounting mix protocol", nodeId = node.info #TODO log the config used

  if node.announcedAddresses.len == 0:
    return err("Trying to mount mix without having announced addresses")

  let localaddrStr = node.announcedAddresses[0].toString().valueOr:
    return err("Failed to convert multiaddress to string.")
  info "local addr", localaddr = localaddrStr

  let nodeAddr = localaddrStr & "/p2p/" & $node.peerId
  node.wakuMix = WakuMix.new(
    nodeAddr, node.peerManager, clusterId, mixPrivKey, mixnodes
  ).valueOr:
    error "Waku Mix protocol initialization failed", err = error
    return
  node.wakuMix.registerDestReadBehavior(WakuLightPushCodec, readLp(int(-1)))
  let catchRes = catch:
    node.switch.mount(node.wakuMix)
  if catchRes.isErr():
    return err(catchRes.error.msg)
  return ok()

## Waku Sync

proc mountStoreSync*(
    node: WakuNode,
    cluster: uint16,
    shards: seq[uint16],
    contentTopics: seq[string],
    storeSyncRange: uint32,
    storeSyncInterval: uint32,
    storeSyncRelayJitter: uint32,
): Future[Result[void, string]] {.async.} =
  let idsChannel = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)](0)
  let wantsChannel = newAsyncQueue[(PeerId)](0)
  let needsChannel = newAsyncQueue[(PeerId, WakuMessageHash)](0)

  let pubsubTopics = shards.mapIt($RelayShard(clusterId: cluster, shardId: it))

  let recon =
    ?await SyncReconciliation.new(
      pubsubTopics, contentTopics, node.peerManager, node.wakuArchive,
      storeSyncRange.seconds, storeSyncInterval.seconds, storeSyncRelayJitter.seconds,
      idsChannel, wantsChannel, needsChannel,
    )

  node.wakuStoreReconciliation = recon

  let reconMountRes = catch:
    node.switch.mount(
      node.wakuStoreReconciliation, protocolMatcher(WakuReconciliationCodec)
    )
  if reconMountRes.isErr():
    return err(reconMountRes.error.msg)

  let transfer = SyncTransfer.new(
    node.peerManager, node.wakuArchive, idsChannel, wantsChannel, needsChannel
  )

  node.wakuStoreTransfer = transfer

  let transMountRes = catch:
    node.switch.mount(node.wakuStoreTransfer, protocolMatcher(WakuTransferCodec))
  if transMountRes.isErr():
    return err(transMountRes.error.msg)

  return ok()

proc startRelay*(node: WakuNode) {.async.} =
  ## Setup and start relay protocol
  info "starting relay protocol"

  if node.wakuRelay.isNil():
    error "Failed to start relay. Not mounted."
    return

  ## Setup relay protocol

  # Resume previous relay connections
  if node.peerManager.switch.peerStore.hasPeers(protocolMatcher(WakuRelayCodec)):
    info "Found previous WakuRelay peers. Reconnecting."

    # Reconnect to previous relay peers. This will respect a backoff period, if necessary
    let backoffPeriod =
      node.wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime)

    await node.peerManager.reconnectPeers(WakuRelayCodec, backoffPeriod)

  # Start the WakuRelay protocol
  await node.wakuRelay.start()

  info "relay started successfully"

proc selectRandomPeers*(peers: seq[PeerId], numRandomPeers: int): seq[PeerId] =
  var randomPeers = peers
  shuffle(randomPeers)
  return randomPeers[0 ..< min(len(randomPeers), numRandomPeers)]

proc mountRendezvous*(node: WakuNode, clusterId: uint16) {.async: (raises: []).} =
  info "mounting rendezvous discovery protocol"

  node.wakuRendezvous = WakuRendezVous.new(
    node.switch,
    node.peerManager,
    clusterId,
    node.getShardsGetter(),
    node.getCapabilitiesGetter(),
  ).valueOr:
    error "initializing waku rendezvous failed", error = error
    return

  if node.started:
    await node.wakuRendezvous.start()

proc isBindIpWithZeroPort(inputMultiAdd: MultiAddress): bool =
  let inputStr = $inputMultiAdd
  if inputStr.contains("0.0.0.0/tcp/0") or inputStr.contains("127.0.0.1/tcp/0"):
    return true

  return false

proc updateAnnouncedAddrWithPrimaryIpAddr*(node: WakuNode): Result[void, string] =
  let peerInfo = node.switch.peerInfo
  var announcedStr = ""
  var listenStr = ""
  var localIp = "0.0.0.0"

  try:
    localIp = $getPrimaryIPAddr()
  except Exception as e:
    warn "Could not retrieve localIp", msg = e.msg

  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs

  ## Update the WakuNode addresses
  var newAnnouncedAddresses = newSeq[MultiAddress](0)
  for address in node.announcedAddresses:
    ## Replace "0.0.0.0" or "127.0.0.1" with the localIp
    let newAddr = ($address).replace("0.0.0.0", localIp).replace("127.0.0.1", localIp)
    let fulladdr = "[" & $newAddr & "/p2p/" & $peerInfo.peerId & "]"
    announcedStr &= fulladdr
    let newMultiAddr = MultiAddress.init(newAddr).valueOr:
      return err("error in updateAnnouncedAddrWithPrimaryIpAddr: " & $error)
    newAnnouncedAddresses.add(newMultiAddr)

  node.announcedAddresses = newAnnouncedAddresses

  ## Update the Switch addresses
  node.switch.peerInfo.addrs = newAnnouncedAddresses

  for transport in node.switch.transports:
    for address in transport.addrs:
      let fulladdr = "[" & $address & "/p2p/" & $peerInfo.peerId & "]"
      listenStr &= fulladdr

  info "Listening on",
    full = listenStr, localIp = localIp, switchAddress = $(node.switch.peerInfo.addrs)
  info "Announcing addresses", full = announcedStr
  info "DNS: discoverable ENR ", enr = node.enr.toUri()

  return ok()

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.

  waku_version.set(1, labelValues = [git_version])
  info "Starting Waku node", version = git_version

  var zeroPortPresent = false
  for address in node.announcedAddresses:
    if isBindIpWithZeroPort(address):
      zeroPortPresent = true

  # Perform relay-specific startup tasks TODO: this should be rethought
  if not node.wakuRelay.isNil():
    await node.startRelay()

  if not node.wakuMix.isNil():
    node.wakuMix.start()

  if not node.wakuMetadata.isNil():
    node.wakuMetadata.start()

  if not node.wakuStoreResume.isNil():
    await node.wakuStoreResume.start()

  if not node.wakuRendezvous.isNil():
    await node.wakuRendezvous.start()

  if not node.wakuStoreReconciliation.isNil():
    node.wakuStoreReconciliation.start()

  if not node.wakuStoreTransfer.isNil():
    node.wakuStoreTransfer.start()

  ## The switch uses this mapper to update peer info addrs
  ## with announced addrs after start
  let addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
    return node.announcedAddresses
  node.switch.peerInfo.addressMappers.add(addressMapper)

  ## The switch will update addresses after start using the addressMapper
  await node.switch.start()

  node.started = true

  if not zeroPortPresent:
    updateAnnouncedAddrWithPrimaryIpAddr(node).isOkOr:
      error "failed update announced addr", error = $error
  else:
    info "Listening port is dynamically allocated, address and ENR generation postponed"

  info "Node started successfully"

proc stop*(node: WakuNode) {.async.} =
  ## By stopping the switch we are stopping all the underlying mounted protocols
  await node.switch.stop()

  node.peerManager.stop()

  if not node.wakuRlnRelay.isNil():
    try:
      await node.wakuRlnRelay.stop() ## this can raise an exception
    except Exception:
      error "exception stopping the node", error = getCurrentExceptionMsg()

  if not node.wakuArchive.isNil():
    await node.wakuArchive.stopWait()

  if not node.wakuStoreResume.isNil():
    await node.wakuStoreResume.stopWait()

  if not node.wakuStoreReconciliation.isNil():
    node.wakuStoreReconciliation.stop()

  if not node.wakuStoreTransfer.isNil():
    node.wakuStoreTransfer.stop()

  if not node.wakuPeerExchange.isNil() and not node.wakuPeerExchange.pxLoopHandle.isNil():
    await node.wakuPeerExchange.pxLoopHandle.cancelAndWait()

  if not node.wakuPeerExchangeClient.isNil() and
      not node.wakuPeerExchangeClient.pxLoopHandle.isNil():
    await node.wakuPeerExchangeClient.pxLoopHandle.cancelAndWait()

  if not node.wakuRendezvous.isNil():
    await node.wakuRendezvous.stopWait()

  node.started = false

proc isReady*(node: WakuNode): Future[bool] {.async: (raises: [Exception]).} =
  if node.wakuRlnRelay == nil:
    return true
  return await node.wakuRlnRelay.isReady()
  ## TODO: add other protocol `isReady` checks
