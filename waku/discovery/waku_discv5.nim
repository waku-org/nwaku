{.push raises: [].}

import
  std/[sequtils, strutils, options, sets, net, json],
  results,
  chronos,
  chronicles,
  metrics,
  libp2p/multiaddress,
  eth/keys as eth_keys,
  eth/p2p/discoveryv5/node,
  eth/p2p/discoveryv5/protocol
import
  ../node/peer_manager/peer_manager,
  ../waku_core,
  ../waku_enr,
  ../factory/external_config

export protocol, waku_enr

declarePublicGauge waku_discv5_discovered, "number of nodes discovered"
declarePublicGauge waku_discv5_errors, "number of waku discv5 errors", ["type"]

logScope:
  topics = "waku discv5"

## Config

type WakuDiscoveryV5Config* = object
  discv5Config*: Option[DiscoveryConfig]
  address*: IpAddress
  port*: Port
  privateKey*: eth_keys.PrivateKey
  bootstrapRecords*: seq[waku_enr.Record]
  autoupdateRecord*: bool

## Protocol

type WakuDiscv5Predicate* =
  proc(record: waku_enr.Record): bool {.closure, gcsafe, raises: [].}

type WakuDiscoveryV5* = ref object
  conf: WakuDiscoveryV5Config
  protocol*: protocol.Protocol
  listening*: bool
  predicate: Option[WakuDiscv5Predicate]
  peerManager: Option[PeerManager]
  topicSubscriptionQueue: AsyncEventQueue[SubscriptionEvent]

proc shardingPredicate*(
    record: Record, bootnodes: seq[Record] = @[]
): Option[WakuDiscv5Predicate] =
  ## Filter peers based on relay sharding information
  let typedRecord = record.toTyped().valueOr:
    debug "peer filtering failed", reason = error
    return none(WakuDiscv5Predicate)

  let nodeShard = typedRecord.relaySharding().valueOr:
    debug "no relay sharding information, peer filtering disabled"
    return none(WakuDiscv5Predicate)

  debug "peer filtering updated"

  let predicate = proc(record: waku_enr.Record): bool =
    bootnodes.contains(record) or # Temp. Bootnode exception
    (
      record.getCapabilities().len > 0 and #RFC 31 requirement
      nodeShard.shardIds.anyIt(record.containsShard(nodeShard.clusterId, it))
    ) #RFC 64 guideline

  return some(predicate)

proc new*(
    T: type WakuDiscoveryV5,
    rng: ref HmacDrbgContext,
    conf: WakuDiscoveryV5Config,
    record: Option[waku_enr.Record],
    peerManager: Option[PeerManager] = none(PeerManager),
    queue: AsyncEventQueue[SubscriptionEvent] =
      newAsyncEventQueue[SubscriptionEvent](30),
): T =
  let protocol = newProtocol(
    rng = rng,
    config = conf.discv5Config.get(protocol.defaultDiscoveryConfig),
    bindPort = conf.port,
    bindIp = conf.address,
    privKey = conf.privateKey,
    bootstrapRecords = conf.bootstrapRecords,
    enrAutoUpdate = conf.autoupdateRecord,
    previousRecord = record,
    enrIp = none(IpAddress),
    enrTcpPort = none(Port),
    enrUdpPort = none(Port),
  )

  let shardPredOp =
    if record.isSome():
      shardingPredicate(record.get(), conf.bootstrapRecords)
    else:
      none(WakuDiscv5Predicate)

  WakuDiscoveryV5(
    conf: conf,
    protocol: protocol,
    listening: false,
    predicate: shardPredOp,
    peerManager: peerManager,
    topicSubscriptionQueue: queue,
  )

proc updateAnnouncedMultiAddress*(
    wd: WakuDiscoveryV5, addresses: seq[MultiAddress]
): Result[void, string] =
  let encodedAddrs = multiaddr.encodeMultiaddrs(addresses)

  wd.protocol.updateRecord([(MultiaddrEnrField, encodedAddrs)]).isOkOr:
    return err("failed to update multiaddress in ENR: " & $error)

  debug "ENR updated successfully with new multiaddress",
    enr = wd.protocol.localNode.record.toUri(), record = $(wd.protocol.localNode.record)

  return ok()

proc updateENRShards(
    wd: WakuDiscoveryV5, newTopics: seq[PubsubTopic], add: bool
): Result[void, string] =
  ## Add or remove shards from the Discv5 ENR
  let newShardOp = topicsToRelayShards(newTopics).valueOr:
    return err("ENR update failed: " & error)

  let newShard = newShardOp.valueOr:
    return ok()

  let typedRecord = wd.protocol.localNode.record.toTyped().valueOr:
    return err("ENR update failed: " & $error)

  let currentShardsOp = typedRecord.relaySharding()

  let resultShard =
    if add and currentShardsOp.isSome():
      let currentShard = currentShardsOp.get()

      if currentShard.clusterId != newShard.clusterId:
        return err("ENR update failed: clusterId id mismatch")

      RelayShards.init(
        currentShard.clusterId, currentShard.shardIds & newShard.shardIds
      ).valueOr:
        return err("ENR update failed: " & error)
    elif not add and currentShardsOp.isSome():
      let currentShard = currentShardsOp.get()

      if currentShard.clusterId != newShard.clusterId:
        return err("ENR update failed: clusterId id mismatch")

      let currentSet = toHashSet(currentShard.shardIds)
      let newSet = toHashSet(newShard.shardIds)

      let indices = toSeq(currentSet - newSet)

      if indices.len == 0:
        return err("ENR update failed: cannot remove all shards")

      RelayShards.init(currentShard.clusterId, indices).valueOr:
        return err("ENR update failed: " & error)
    elif add and currentShardsOp.isNone():
      newShard
    else:
      return ok()

  let (field, value) =
    if resultShard.shardIds.len >= ShardingIndicesListMaxLength:
      (ShardingBitVectorEnrField, resultShard.toBitVector())
    else:
      let list = resultShard.toIndicesList().valueOr:
        return err("ENR update failed: " & $error)

      (ShardingIndicesListEnrField, list)

  wd.protocol.updateRecord([(field, value)]).isOkOr:
    return err("ENR update failed: " & $error)

  return ok()

proc logDiscv5FoundPeers(discoveredRecords: seq[waku_enr.Record]) =
  for record in discoveredRecords:
    let recordUri = record.toURI()
    let capabilities = record.getCapabilities()

    let typedRecord = record.toTyped().valueOr:
      warn "Could not parse to typed record", error = error, enr = recordUri
      continue

    let peerInfo = record.toRemotePeerInfo().valueOr:
      warn "Could not generate remote peer info", error = error, enr = recordUri
      continue

    let addrs = peerInfo.constructMultiaddrStr()

    let rs = typedRecord.relaySharding()
    let shardsStr =
      if rs.isSome():
        $rs.get()
      else:
        "no shards found"

    notice "Received discv5 node",
      addrs = addrs, enr = recordUri, capabilities = capabilities, shards = shardsStr

proc findRandomPeers*(
    wd: WakuDiscoveryV5, overridePred = none(WakuDiscv5Predicate)
): Future[seq[waku_enr.Record]] {.async.} =
  ## Find random peers to connect to using Discovery v5
  let discoveredNodes = await wd.protocol.queryRandom()

  var discoveredRecords = discoveredNodes.mapIt(it.record)

  when defined(debugDiscv5):
    logDiscv5FoundPeers(discoveredRecords)

  # Filter out nodes that do not match the predicate
  if overridePred.isSome():
    discoveredRecords = discoveredRecords.filter(overridePred.get())
  elif wd.predicate.isSome():
    discoveredRecords = discoveredRecords.filter(wd.predicate.get())

  waku_discv5_discovered.inc(discoveredRecords.len)

  return discoveredRecords

proc searchLoop(wd: WakuDiscoveryV5) {.async.} =
  ## Continuously add newly discovered nodes

  let peerManager = wd.peerManager.valueOr:
    return

  info "Starting discovery v5 search"

  while wd.listening:
    trace "running discv5 discovery loop"
    let discoveredRecords = await wd.findRandomPeers()

    var discoveredPeers: seq[RemotePeerInfo]
    var wrongRecordsReasons: seq[tuple[record: string, errorDescription: string]]
      ## this is to store the reasons why certain records could not be converted to RemotePeerInfo

    for record in discoveredRecords:
      let peerInfo = record.toRemotePeerInfo().valueOr:
        ## in case of error, we keep track of it for debugging purposes
        wrongRecordsReasons.add(($record, $error))
        waku_discv5_errors.inc(labelValues = [$error])
        continue

      discoveredPeers.add(peerInfo)

    trace "discv5 discovered peers",
      num_discovered_peers = discoveredPeers.len,
      peers = toSeq(discoveredPeers.mapIt(shortLog(it.peerId)))

    trace "discv5 discarded wrong records",
      wrong_records =
        wrongRecordsReasons.mapIt("(" & it.record & "," & it.errorDescription & ")")

    for peer in discoveredPeers:
      # Peers added are filtered by the peer manager
      peerManager.addPeer(peer, PeerOrigin.Discv5)

    # Discovery `queryRandom` can have a synchronous fast path for example
    # when no peers are in the routing table. Don't run it in continuous loop.
    #
    # Also, give some time to dial the discovered nodes and update stats, etc.
    await sleepAsync(5.seconds)

proc subscriptionsListener(wd: WakuDiscoveryV5) {.async.} =
  ## Listen for pubsub topics subscriptions changes

  let key = wd.topicSubscriptionQueue.register()

  while wd.listening:
    let events = await wd.topicSubscriptionQueue.waitEvents(key)

    # Since we don't know the events we will receive we have to anticipate.

    let subs = events.filterIt(it.kind == PubsubSub).mapIt(it.topic)
    let unsubs = events.filterIt(it.kind == PubsubUnsub).mapIt(it.topic)

    if subs.len == 0 and unsubs.len == 0:
      continue

    let unsubRes = wd.updateENRShards(unsubs, false)
    let subRes = wd.updateENRShards(subs, true)

    if subRes.isErr():
      debug "ENR shard addition failed", reason = $subRes.error

    if unsubRes.isErr():
      debug "ENR shard removal failed", reason = $unsubRes.error

    if subRes.isErr() and unsubRes.isErr():
      continue

    debug "ENR updated successfully",
      enrUri = wd.protocol.localNode.record.toUri(),
      enr = $(wd.protocol.localNode.record)

    wd.predicate =
      shardingPredicate(wd.protocol.localNode.record, wd.protocol.bootstrapRecords)

  wd.topicSubscriptionQueue.unregister(key)

proc start*(wd: WakuDiscoveryV5): Future[Result[void, string]] {.async: (raises: []).} =
  if wd.listening:
    return err("already listening")

  info "Starting discovery v5 service"

  debug "start listening on udp port", address = $wd.conf.address, port = $wd.conf.port
  try:
    wd.protocol.open()
  except CatchableError:
    return err("failed to open udp port: " & getCurrentExceptionMsg())

  wd.listening = true

  trace "start discv5 service"
  wd.protocol.start()

  asyncSpawn wd.searchLoop()
  asyncSpawn wd.subscriptionsListener()

  debug "Successfully started discovery v5 service"
  info "Discv5: discoverable ENR ",
    enrUri = wd.protocol.localNode.record.toUri(), enr = $(wd.protocol.localNode.record)

  ok()

proc stop*(wd: WakuDiscoveryV5): Future[void] {.async.} =
  if not wd.listening:
    return

  info "Stopping discovery v5 service"

  wd.listening = false
  trace "Stop listening on discv5 port"
  await wd.protocol.closeWait()

  debug "Successfully stopped discovery v5 service"

## Helper functions

proc parseBootstrapAddress(address: string): Result[enr.Record, cstring] =
  logScope:
    address = address

  if address[0] == '/':
    return err("MultiAddress bootstrap addresses are not supported")

  let lowerCaseAddress = toLowerAscii(address)
  if lowerCaseAddress.startsWith("enr:"):
    var enrRec: enr.Record
    if not enrRec.fromURI(address):
      return err("Invalid ENR bootstrap record")

    return ok(enrRec)
  elif lowerCaseAddress.startsWith("enode:"):
    return err("ENode bootstrap addresses are not supported")
  else:
    return err("Ignoring unrecognized bootstrap address type")

proc addBootstrapNode*(bootstrapAddr: string, bootstrapEnrs: var seq[enr.Record]) =
  # Ignore empty lines or lines starting with #
  if bootstrapAddr.len == 0 or bootstrapAddr[0] == '#':
    return

  let enrRes = parseBootstrapAddress(bootstrapAddr)
  if enrRes.isErr():
    debug "ignoring invalid bootstrap address", reason = enrRes.error
    return

  bootstrapEnrs.add(enrRes.value)

proc setupDiscoveryV5*(
    myENR: enr.Record,
    nodePeerManager: PeerManager,
    nodeTopicSubscriptionQueue: AsyncEventQueue[SubscriptionEvent],
    conf: WakuNodeConf,
    dynamicBootstrapNodes: seq[RemotePeerInfo],
    rng: ref HmacDrbgContext,
    key: crypto.PrivateKey,
): WakuDiscoveryV5 =
  let dynamicBootstrapEnrs =
    dynamicBootstrapNodes.filterIt(it.hasUdpPort()).mapIt(it.enr.get())

  var discv5BootstrapEnrs: seq[enr.Record]

  # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
  for enrUri in conf.discv5BootstrapNodes:
    addBootstrapNode(enrUri, discv5BootstrapEnrs)

  discv5BootstrapEnrs.add(dynamicBootstrapEnrs)

  let discv5Config = DiscoveryConfig.init(
    conf.discv5TableIpLimit, conf.discv5BucketIpLimit, conf.discv5BitsPerHop
  )

  let discv5UdpPort = Port(uint16(conf.discv5UdpPort) + conf.portsShift)

  let discv5Conf = WakuDiscoveryV5Config(
    discv5Config: some(discv5Config),
    address: conf.listenAddress,
    port: discv5UdpPort,
    privateKey: eth_keys.PrivateKey(key.skkey),
    bootstrapRecords: discv5BootstrapEnrs,
    autoupdateRecord: conf.discv5EnrAutoUpdate,
  )

  WakuDiscoveryV5.new(
    rng, discv5Conf, some(myENR), some(nodePeerManager), nodeTopicSubscriptionQueue
  )

proc updateBootstrapRecords*(
    self: var WakuDiscoveryV5, newRecordsString: string
): Result[void, string] =
  ## newRecordsString - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
  var newRecords = newSeq[waku_enr.Record]()

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(newRecordsString)
  except Exception:
    return err("exception parsing json enr records: " & getCurrentExceptionMsg())

  if jsonNode.kind != JArray:
    return err("updateBootstrapRecords should receive a json array containing ENRs")

  for enr in jsonNode:
    let enrWithoutQuotes = ($enr).replace("\"", "")
    var bootstrapNodeEnr: waku_enr.Record
    if not bootstrapNodeEnr.fromURI(enrWithoutQuotes):
      return err("wrong enr given: " & enrWithoutQuotes)

  self.protocol.bootstrapRecords = newRecords

  return ok()
