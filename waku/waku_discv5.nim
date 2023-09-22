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
import
  ./node/peer_manager/peer_manager,
  ./waku_core,
  ./waku_enr

export protocol, waku_enr


declarePublicGauge waku_discv5_discovered, "number of nodes discovered"
declarePublicGauge waku_discv5_errors, "number of waku discv5 errors", ["type"]

logScope:
  topics = "waku discv5"


## Config

type WakuDiscoveryV5Config* = object
    discv5Config*: Option[DiscoveryConfig]
    address*: ValidIpAddress
    port*: Port
    privateKey*: eth_keys.PrivateKey
    bootstrapRecords*: seq[waku_enr.Record]
    autoupdateRecord*: bool


## Protocol

type WakuDiscv5Predicate* = proc(record: waku_enr.Record): bool {.closure, gcsafe, raises: [].}

type WakuDiscoveryV5* = ref object
    conf: WakuDiscoveryV5Config
    protocol*: protocol.Protocol
    listening*: bool
    predicate: Option[WakuDiscv5Predicate]

proc shardingPredicate*(record: Record): Option[WakuDiscv5Predicate] =
  ## Filter peers based on relay sharding information

  let typeRecordRes = record.toTyped()
  let typedRecord =
    if typeRecordRes.isErr():
      debug "peer filtering failed", reason= $typeRecordRes.error
      return none(WakuDiscv5Predicate)
    else: typeRecordRes.get()

  let nodeShardOp = typedRecord.relaySharding()
  let nodeShard =
    if nodeShardOp.isNone():
      debug "no relay sharding information, peer filtering disabled"
      return none(WakuDiscv5Predicate)
    else: nodeShardOp.get()

  debug "peer filtering updated"

  let predicate = proc(record: waku_enr.Record): bool =
      nodeShard.indices.anyIt(record.containsShard(nodeShard.cluster, it))

  return some(predicate)

proc new*(
  T: type WakuDiscoveryV5,
  rng: ref HmacDrbgContext,
  conf: WakuDiscoveryV5Config,
  record: Option[waku_enr.Record]
  ): T =
  let shardPredOp =
    if record.isSome(): shardingPredicate(record.get())
    else: none(WakuDiscv5Predicate)
  
  var bootstrapRecords = conf.bootstrapRecords

  # Remove bootstrap nodes with which we don't share shards.
  if shardPredOp.isSome():
    bootstrapRecords.keepIf(shardPredOp.get())
  
  if conf.bootstrapRecords.len > 0 and bootstrapRecords.len == 0:
    warn "No discv5 bootstrap nodes share this node configured shards"

  let protocol = newProtocol(
    rng = rng,
    config = conf.discv5Config.get(protocol.defaultDiscoveryConfig),
    bindPort = conf.port,
    bindIp = conf.address,
    privKey = conf.privateKey,
    bootstrapRecords = bootstrapRecords,
    enrAutoUpdate = conf.autoupdateRecord,
    previousRecord = record,
    enrIp = none(ValidIpAddress),
    enrTcpPort = none(Port),
    enrUdpPort = none(Port),
  )

  WakuDiscoveryV5(conf: conf, protocol: protocol, listening: false, predicate: shardPredOp)

proc new*(T: type WakuDiscoveryV5,
          extIp: Option[ValidIpAddress],
          extTcpPort: Option[Port],
          extUdpPort: Option[Port],
          bindIP: ValidIpAddress,
          discv5UdpPort: Port,
          bootstrapEnrs = newSeq[enr.Record](),
          enrAutoUpdate = false,
          privateKey: eth_keys.PrivateKey,
          flags: CapabilitiesBitfield,
          multiaddrs = newSeq[MultiAddress](),
          rng: ref HmacDrbgContext,
          topics: seq[string],
          discv5Config: protocol.DiscoveryConfig = protocol.defaultDiscoveryConfig
          ): T {.
  deprecated: "use the config and record proc variant instead".}=

  let relayShardsRes = topicsToRelayShards(topics)

  let relayShard =
    if relayShardsRes.isErr():
      debug "pubsub topic parsing error", reason = relayShardsRes.error
      none(RelayShards)
    else: relayShardsRes.get()

  let record = block:
        var builder = EnrBuilder.init(privateKey)
        builder.withIpAddressAndPorts(
            ipAddr = extIp,
            tcpPort = extTcpPort,
            udpPort = extUdpPort,
        )
        builder.withWakuCapabilities(flags)
        builder.withMultiaddrs(multiaddrs)

        if relayShard.isSome():
          let res = builder.withWakuRelaySharding(relayShard.get())

          if res.isErr():
            debug "building ENR with relay sharding failed", reason = res.error
          else:
            debug "building ENR with relay sharding information", cluster = $relayShard.get().cluster(), shards = $relayShard.get().indices()

        builder.build().expect("Record within size limits")

  let conf = WakuDiscoveryV5Config(
    discv5Config: some(discv5Config),
    address: bindIP,
    port: discv5UdpPort,
    privateKey: privateKey,
    bootstrapRecords: bootstrapEnrs,
    autoupdateRecord: enrAutoUpdate,
  )

  WakuDiscoveryV5.new(rng, conf, some(record))

proc updateENRShards(wd: WakuDiscoveryV5,
  newTopics: seq[PubsubTopic], add: bool):  Result[void, string] =
  ## Add or remove shards from the Discv5 ENR

  let newShardOp = ?topicsToRelayShards(newTopics)

  let newShard =
    if newShardOp.isSome():
      newShardOp.get()
    else:
      return ok()

  let typedRecordRes = wd.protocol.localNode.record.toTyped()
  let typedRecord =
    if typedRecordRes.isErr():
      return err($typedRecordRes.error)
    else:
      typedRecordRes.get()

  let currentShardsOp = typedRecord.relaySharding()

  let resultShard =
    if add and currentShardsOp.isSome():
      let currentShard = currentShardsOp.get()

      if currentShard.cluster != newShard.cluster:
        return err("ENR are limited to one shard cluster")

      ?RelayShards.init(currentShard.cluster, currentShard.indices & newShard.indices)
    elif not add and currentShardsOp.isSome():
      let currentShard = currentShardsOp.get()

      if currentShard.cluster != newShard.cluster:
        return err("ENR are limited to one shard cluster")

      let currentSet = toHashSet(currentShard.indices)
      let newSet = toHashSet(newShard.indices)

      let indices = toSeq(currentSet - newSet)

      if indices.len == 0:
        # Can't create RelayShard with no indices so update then return
        let (field, value) = (ShardingIndicesListEnrField, newSeq[byte](3))

        let res = wd.protocol.updateRecord([(field, value)])
        if res.isErr():
          return err($res.error)

        return ok()

      ?RelayShards.init(currentShard.cluster, indices)
    elif add and currentShardsOp.isNone(): newShard
    else: return ok()
  
  let (field, value) =
    if resultShard.indices.len >= ShardingIndicesListMaxLength:
      (ShardingBitVectorEnrField, resultShard.toBitVector())
    else:
      let listRes = resultShard.toIndicesList()
      let list = 
        if listRes.isErr():
          return err($listRes.error)
        else:
          listRes.get()

      (ShardingIndicesListEnrField, list)

  let res = wd.protocol.updateRecord([(field, value)])
  if res.isErr():
    return err($res.error)

  return ok()

proc findRandomPeers*(wd: WakuDiscoveryV5, overridePred = none(WakuDiscv5Predicate)): Future[seq[waku_enr.Record]] {.async.} =
  ## Find random peers to connect to using Discovery v5
  let discoveredNodes = await wd.protocol.queryRandom()

  var discoveredRecords = discoveredNodes.mapIt(it.record)

  # Filter out nodes that do not match the predicate
  if overridePred.isSome():
    discoveredRecords = discoveredRecords.filter(overridePred.get())
  elif wd.predicate.isSome():
    discoveredRecords = discoveredRecords.filter(wd.predicate.get())

  return discoveredRecords

#TODO abstract away PeerManager
proc searchLoop*(wd: WakuDiscoveryV5, peerManager: PeerManager) {.async.} =
  ## Continuously add newly discovered nodes

  info "Starting discovery v5 search"

  while wd.listening:
    trace "running discv5 discovery loop"
    let discoveredRecords = await wd.findRandomPeers()
    let discoveredPeers = discoveredRecords.mapIt(it.toRemotePeerInfo()).filterIt(it.isOk()).mapIt(it.value)

    for peer in discoveredPeers:
      # Peers added are filtered by the peer manager
      peerManager.addPeer(peer, PeerOrigin.Discv5)

    # Discovery `queryRandom` can have a synchronous fast path for example
    # when no peers are in the routing table. Don't run it in continuous loop.
    #
    # Also, give some time to dial the discovered nodes and update stats, etc.
    await sleepAsync(5.seconds)

proc start*(wd: WakuDiscoveryV5): Result[void, string] =
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

  debug "Successfully started discovery v5 service"
  info "Discv5: discoverable ENR ", enr = wd.protocol.localNode.record.toUri()

  ok()

proc stop*(wd: WakuDiscoveryV5): Future[void] {.async.} =
  if not wd.listening:
      return

  info "Stopping discovery v5 service"

  wd.listening = false
  trace "Stop listening on discv5 port"
  await wd.protocol.closeWait()

  debug "Successfully stopped discovery v5 service"

proc subscriptionsListener*(wd: WakuDiscoveryV5, topicSubscriptionQueue: AsyncEventQueue[SubscriptionEvent]) {.async.} =
  ## Listen for pubsub topics subscriptions changes
  
  let key = topicSubscriptionQueue.register()

  while wd.listening:
    let events = await topicSubscriptionQueue.waitEvents(key)

    # Since we don't know the events we will receive we have to anticipate.

    let subs = events.filterIt(it.kind == SubscriptionKind.PubsubSub).mapIt(it.pubsubSub)
    let unsubs = events.filterIt(it.kind == SubscriptionKind.PubsubUnsub).mapIt(it.pubsubUnsub)

    if subs.len == 0 and unsubs.len == 0:
      continue

    let unsubRes = wd.updateENRShards(unsubs, false)
    let subRes = wd.updateENRShards(subs, true)

    if subRes.isErr():
      debug "ENR shard addition failed", reason= $subRes.error
    
    if unsubRes.isErr():
      debug "ENR shard removal failed", reason= $unsubRes.error

    if subRes.isErr() and unsubRes.isErr():
      continue

    debug "ENR updated successfully"

    wd.predicate = shardingPredicate(wd.protocol.localNode.record)

  topicSubscriptionQueue.unregister(key)

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

proc addBootstrapNode*(bootstrapAddr: string,
                       bootstrapEnrs: var seq[enr.Record]) =
  # Ignore empty lines or lines starting with #
  if bootstrapAddr.len == 0 or bootstrapAddr[0] == '#':
    return

  let enrRes = parseBootstrapAddress(bootstrapAddr)
  if enrRes.isErr():
    debug "ignoring invalid bootstrap address", reason = enrRes.error
    return

  bootstrapEnrs.add(enrRes.value)
