when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sequtils, strutils, options, sets],
  stew/results,
  stew/shims/net,
  chronos,
  chronicles,
  metrics,
  libp2p/multiaddress,
  eth/keys as eth_keys,
  eth/p2p/discoveryv5/node,
  eth/p2p/discoveryv5/protocol
import ./node/peer_manager/peer_manager, ./waku_core, ./waku_enr

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
    debug "ivan", reason = error
    return none(WakuDiscv5Predicate)

  let nodeShard = typedRecord.relaySharding().valueOr:
    debug "no relay sharding information, peer filtering disabled"
    debug "ivan"
    return none(WakuDiscv5Predicate)

  debug "peer filtering updated"

  let predicate = proc(record: waku_enr.Record): bool =
    let ret =
      bootnodes.contains(record) or # Temp. Bootnode exception
      (
        record.getCapabilities().len > 0 and #RFC 31 requirement
        nodeShard.shardIds.anyIt(record.containsShard(nodeShard.clusterId, it))
      ) #RFC 64 guideline

    # debug "ivan", ret, contains = bootnodes.contains(record), record, nodeShard

    ret

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
      debug "ivan"
      shardingPredicate(record.get(), conf.bootstrapRecords)
    else:
      debug "ivan"
      none(WakuDiscv5Predicate)

  WakuDiscoveryV5(
    conf: conf,
    protocol: protocol,
    listening: false,
    predicate: shardPredOp,
    peerManager: peerManager,
    topicSubscriptionQueue: queue,
  )

proc updateENRShards(
    wd: WakuDiscoveryV5, newTopics: seq[PubsubTopic], add: bool
): Result[void, string] =
  ## Add or remove shards from the Discv5 ENR
  debug "ivan"
  let newShardOp = topicsToRelayShards(newTopics).valueOr:
    debug "ivan", error = error
    return err("ENR update failed: " & error)

  debug "ivan"

  let newShard = newShardOp.valueOr:
    debug "ivan"
    return ok()

  debug "ivan"

  let typedRecord = wd.protocol.localNode.record.toTyped().valueOr:
    debug "ivan", error = $error
    return err("ENR update failed: " & $error)
  debug "ivan", typedRecord

  let currentShardsOp = typedRecord.relaySharding()

  let resultShard =
    if add and currentShardsOp.isSome():
      debug "ivan", currentShardsOp
      let currentShard = currentShardsOp.get()

      if currentShard.clusterId != newShard.clusterId:
        debug "ivan", current = currentShard.clusterId, newshard = newShard.clusterId
        return err("ENR update failed: clusterId id mismatch")
      debug "ivan"

      RelayShards.init(
        currentShard.clusterId, currentShard.shardIds & newShard.shardIds
      ).valueOr:
        debug "ivan"
        return err("ENR update failed: " & error)
    elif not add and currentShardsOp.isSome():
      debug "ivan"
      let currentShard = currentShardsOp.get()
      debug "ivan", currentShard

      if currentShard.clusterId != newShard.clusterId:
        debug "ivan", current = currentShard.clusterId, newshard = newShard.clusterId
        return err("ENR update failed: clusterId id mismatch")

      let currentSet = toHashSet(currentShard.shardIds)
      let newSet = toHashSet(newShard.shardIds)

      let indices = toSeq(currentSet - newSet)

      if indices.len == 0:
        debug "ivan"
        return err("ENR update failed: cannot remove all shards")

      RelayShards.init(currentShard.clusterId, indices).valueOr:
        debug "ivan"
        return err("ENR update failed: " & error)
    elif add and currentShardsOp.isNone():
      debug "ivan", currentShardsOp
      newShard
    else:
      debug "ivan"
      return ok()

  let (field, value) =
    if resultShard.shardIds.len >= ShardingIndicesListMaxLength:
      debug "ivan"
      (ShardingBitVectorEnrField, resultShard.toBitVector())
    else:
      let list = resultShard.toIndicesList().valueOr:
        debug "ivan"
        return err("ENR update failed: " & $error)

      (ShardingIndicesListEnrField, list)

  wd.protocol.updateRecord([(field, value)]).isOkOr:
    debug "ivan", error
    return err("ENR update failed: " & $error)

  debug "ivan"
  return ok()

proc findRandomPeers*(
    wd: WakuDiscoveryV5, overridePred = none(WakuDiscv5Predicate)
): Future[seq[waku_enr.Record]] {.async.} =
  ## Find random peers to connect to using Discovery v5
  debug "ivan"
  let discoveredNodes = await wd.protocol.queryRandom()
  debug "ivan", discoveredNodes

  var discoveredRecords = discoveredNodes.mapIt(it.record)
  debug "ivan", discoveredRecords

  # Filter out nodes that do not match the predicate
  if overridePred.isSome():
    debug "ivan"
    discoveredRecords = discoveredRecords.filter(overridePred.get())
    debug "ivan", discoveredRecords
  elif wd.predicate.isSome():
    debug "ivan"
    discoveredRecords = discoveredRecords.filter(wd.predicate.get())
    debug "ivan", discoveredRecords

  debug "ivan"
  return discoveredRecords

proc searchLoop(wd: WakuDiscoveryV5) {.async.} =
  ## Continuously add newly discovered nodes

  let peerManager = wd.peerManager.valueOr:
    debug "ivan"
    return

  debug "ivan"
  info "Starting discovery v5 search"

  while wd.listening:
    debug "ivan"
    trace "running discv5 discovery loop"
    let discoveredRecords = await wd.findRandomPeers()
    debug "ivan", discoveredRecords
    let discoveredPeers =
      discoveredRecords.mapIt(it.toRemotePeerInfo()).filterIt(it.isOk()).mapIt(it.value)
    debug "ivan", discoveredRecords

    for peer in discoveredPeers:
      debug "ivan", peer
      # Peers added are filtered by the peer manager
      peerManager.addPeer(peer, PeerOrigin.Discv5)

    # Discovery `queryRandom` can have a synchronous fast path for example
    # when no peers are in the routing table. Don't run it in continuous loop.
    #
    # Also, give some time to dial the discovered nodes and update stats, etc.
    await sleepAsync(5.seconds)

proc subscriptionsListener(wd: WakuDiscoveryV5) {.async.} =
  ## Listen for pubsub topics subscriptions changes

  debug "ivan"
  let key = wd.topicSubscriptionQueue.register()
  debug "ivan"

  while wd.listening:
    debug "ivan"
    let events = await wd.topicSubscriptionQueue.waitEvents(key)

    # Since we don't know the events we will receive we have to anticipate.

    let subs = events.filterIt(it.kind == PubsubSub).mapIt(it.topic)
    let unsubs = events.filterIt(it.kind == PubsubUnsub).mapIt(it.topic)

    if subs.len == 0 and unsubs.len == 0:
      debug "ivan"
      continue

    let unsubRes = wd.updateENRShards(unsubs, false)
    let subRes = wd.updateENRShards(subs, true)

    if subRes.isErr():
      debug "ivan"
      debug "ENR shard addition failed", reason = $subRes.error

    if unsubRes.isErr():
      debug "ivan"
      debug "ENR shard removal failed", reason = $unsubRes.error

    if subRes.isErr() and unsubRes.isErr():
      debug "ivan"
      continue

    debug "ivan"
    debug "ENR updated successfully"

    wd.predicate =
      shardingPredicate(wd.protocol.localNode.record, wd.protocol.bootstrapRecords)

  debug "ivan"
  wd.topicSubscriptionQueue.unregister(key)

proc start*(wd: WakuDiscoveryV5): Future[Result[void, string]] {.async.} =
  if wd.listening:
    return err("already listening")

  debug "ivan"
  info "Starting discovery v5 service"

  debug "start listening on udp port", address = $wd.conf.address, port = $wd.conf.port
  try:
    debug "ivan"
    wd.protocol.open()
    debug "ivan"
  except CatchableError:
    debug "ivan", error = getCurrentExceptionMsg()
    return err("failed to open udp port: " & getCurrentExceptionMsg())

  wd.listening = true

  debug "ivan"
  trace "start discv5 service"
  wd.protocol.start()

  debug "ivan"
  asyncSpawn wd.searchLoop()
  debug "ivan"
  asyncSpawn wd.subscriptionsListener()

  debug "Successfully started discovery v5 service"
  info "Discv5: discoverable ENR ", enr = wd.protocol.localNode.record.toUri()

  debug "ivan"
  ok()

proc stop*(wd: WakuDiscoveryV5): Future[void] {.async.} =
  if not wd.listening:
    debug "ivan"
    return

  info "Stopping discovery v5 service"
  debug "ivan"

  wd.listening = false
  trace "Stop listening on discv5 port"
  await wd.protocol.closeWait()

  debug "Successfully stopped discovery v5 service"
  debug "ivan"

## Helper functions

proc parseBootstrapAddress(address: string): Result[enr.Record, cstring] =
  logScope:
    address = address

  debug "ivan"
  if address[0] == '/':
    debug "ivan"
    return err("MultiAddress bootstrap addresses are not supported")

  let lowerCaseAddress = toLowerAscii(address)
  debug "ivan", lowerCaseAddress
  if lowerCaseAddress.startsWith("enr:"):
    debug "ivan"
    var enrRec: enr.Record
    if not enrRec.fromURI(address):
      debug "ivan"
      return err("Invalid ENR bootstrap record")

    debug "ivan"
    return ok(enrRec)
  elif lowerCaseAddress.startsWith("enode:"):
    debug "ivan"
    return err("ENode bootstrap addresses are not supported")
  else:
    debug "ivan"
    return err("Ignoring unrecognized bootstrap address type")

proc addBootstrapNode*(bootstrapAddr: string, bootstrapEnrs: var seq[enr.Record]) =
  debug "ivan"
  # Ignore empty lines or lines starting with #
  if bootstrapAddr.len == 0 or bootstrapAddr[0] == '#':
    debug "ivan"
    return

  let enrRes = parseBootstrapAddress(bootstrapAddr)
  if enrRes.isErr():
    debug "ivan", error = enrRes.error
    debug "ignoring invalid bootstrap address", reason = enrRes.error
    return

  debug "ivan", value = enrRes.value

  bootstrapEnrs.add(enrRes.value)
