{.push raises: [].}

import
  std/[net],
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/[multiaddress, multicodec, peerinfo, wire],
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p_mix,
  libp2p_mix/mix_protocol,
  libp2p_mix/spam_protection,
  mix_rln_spam_protection/module_api,
  metrics/chronos_httpserver,
  brokers/request_broker
import logos_delivery/kernel/core/time

import
  logos_delivery/kernel/[
    discovery/waku_discv5,
    discovery/discv5_peer_discovery,
    discovery/external_service_discovery,
    factory/app_callbacks,
    protocols/protocols,
    core/topics/pubsub_topic,
    core/message,
    protocols/codecs,
    protocols/lightpush/rpc_codec as lightpush_protocol,
    rln/rln_plugin,
    common/nimchronos,
    protocols/mix/protocol,
    api/events/health_events,
  ],
  logos_delivery/api/events/kernel_events, # MessageSeenEvent
  logos_delivery/kernel/discovery/peer_discovery_interface,
  logos_delivery/kernel/node/delivery_dialer,
  logos_delivery/kernel/[node/peer_manager/peer_manager],
  logos_delivery/kernel/node/shard_subscription,
  logos_delivery/kernel/node/edge_filter_sub_state,
  logos_delivery/kernel/node/subscription_manager

export
  shard_subscription, edge_filter_sub_state, subscription_manager.SubscriptionManager

import logos_delivery/kernel/kernel
import logos_delivery/kernel/protocols/mix/protocol_metrics
import mix_rln_spam_protection/module_api
import logos_delivery/api/events/kernel_events
import logos_delivery/kernel/api/[relay, lightpush]

proc getMixNodePoolSize*(node: Kernel): int =
  ## The number of mix pool members a path can use; zero when mix is not mounted.
  if node.protocols.mix.isNil():
    return 0
  return node.protocols.mix.poolSize()

proc splitMixNodes(
    node: Kernel, mixnodes: seq[MixNodePubInfo]
): tuple[literals: seq[MixNodePubInfo], names: seq[MixNodeName], dropped: int] =
  ## Splits a mix node list into literal entries, which the pool takes as they
  ## are, and `dns4` names to resolve. Drops a bad multiaddress, and a name when
  ## the node has no resolver.
  var
    literals: seq[MixNodePubInfo]
    names: seq[MixNodeName]
    dropped = 0
  for mixnode in mixnodes:
    let address = MultiAddress.init(mixnode.multiAddr).valueOr:
      debug "Skipping a mix node with an invalid multiaddress",
        multiAddr = mixnode.multiAddr, error = error
      logos_delivery_mix_bootnode_resolve_failures.inc()
      dropped.inc()
      continue
    if not DNS.matchPartial(address):
      literals.add(mixnode)
    elif node.switch.nameResolver.isNil():
      debug "Skipping a mix node given by name: the node has no name resolver",
        multiAddr = mixnode.multiAddr
      logos_delivery_mix_bootnode_resolve_failures.inc()
      dropped.inc()
    else:
      names.add((entry: mixnode, address: address))
  return (literals, names, dropped)

proc mixNodesResolved*(node: Kernel) {.async: (raises: [CancelledError]).} =
  ## Waits until the background lookup of the mix node names has finished.
  if not node.protocols.mixNodeResolution.isNil():
    await node.protocols.mixNodeResolution.join()

proc mountMix*(
    node: Kernel,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    mixnodes: seq[MixNodePubInfo],
    spamProtection: Opt[SpamProtection] = Opt.none(SpamProtection),
): Future[Result[void, string]] {.async.} =
  info "Mounting mix protocol", nodeId = node.info #TODO log the config used

  if node.announcedAddresses.len == 0:
    return err("Trying to mount mix without having announced addresses")

  let localaddrStr = node.announcedAddresses[0].toString().valueOr:
    return err("Failed to convert multiaddress to string.")
  info "local addr", localaddr = localaddrStr

  let (literals, names, dropped) = node.splitMixNodes(mixnodes)

  node.protocols.mix = WakuMix.new(
    localaddrStr, node.peerManager, clusterId, mixPrivKey, literals, spamProtection
  ).valueOr:
    return err("Waku Mix protocol initialization failed: " & error)
  #TODO: should we do the below only for exit node? Also, what if multiple protocols use mix?
  node.protocols.mix.registerDestReadBehavior(
    WakuLightPushCodec, readLp(lightpush_protocol.DefaultMaxPushResponseSize)
  )
  let catchRes = catch:
    node.switch.mount(node.protocols.mix)
  catchRes.isOkOr:
    return err(error.msg)

  if dropped > 0:
    warn "Dropped mix nodes that cannot be resolved", dropped = dropped

  # In the background, so a slow or dead DNS server does not hold the start.
  if names.len > 0:
    node.protocols.mixNodeNames = names
    node.protocols.mixNodeResolution = node.resolveMixNodeNames()
  return ok()

proc publishMetadata(
    node: Kernel, topic: string, data: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  var message = WakuMessage(
    payload: data,
    contentTopic: topic,
    timestamp: getNowInNanosecondTime(),
    ephemeral: true,
  )
  # Coordination messages use the node's mounted Relay RLN backend. Mix per-hop
  # proofs use wakuMixRln's separate scope.
  if node.protocols.rlnPlugin.isSome():
    try:
      message = (await attachProof(node.protocols.rlnPlugin, message)).valueOr:
        return err("Failed to attach Relay RLN proof: " & $error)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return err("Relay RLN proof generation failed: " & exc.msg)
  try:
    if not node.protocols.relay.isNil():
      let peers = (await node.publish(Opt.none(PubsubTopic), message)).valueOr:
        return err(error)
      if peers == 0:
        return err("No Relay peers for Mix coordination")
    else:
      discard (
        await node.lightpushPublish(Opt.none(PubsubTopic), message, mixify = false)
      ).valueOr:
        return err("Mix coordination Lightpush failed: " & $error)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return err("Mix coordination publish failed: " & exc.msg)
  return ok()

proc stopMixRln*(node: Kernel) {.async: (raises: []).} =
  if node.protocols.mixRln.isNil():
    return
  if node.protocols.mixRlnListener.isSome():
    await MessageSeenEvent.dropListener(
      node.brokerCtx, node.protocols.mixRlnListener.get()
    )
  node.protocols.mixRlnListener = Opt.none(MessageSeenEventListener)
  await node.protocols.mixRln.stop()

proc startMixRln*(
    node: Kernel
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  if node.protocols.mixRln.isNil():
    return err("Mix RLN is not configured")
  if node.protocols.rlnPlugin.isNone():
    return err("Mix RLN coordination requires Relay RLN")
  let plugin = node.protocols.mixRln
  plugin.setPublishCallback(
    proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
      return await node.publishMetadata(topic, data)
  )
  (await plugin.start()).isOkOr:
    return err("Failed to start Mix RLN plugin: " & $error)
  if node.protocols.mixRlnListener.isSome():
    return ok()
  let handler = proc(event: MessageSeenEvent): Future[void] {.async: (raises: []).} =
    if event.message.contentTopic == plugin.config.metadataTopic:
      plugin.handleProofMetadata(event.message.payload).isOkOr:
        debug "Rejected Mix coordination metadata", error
  let listener = MessageSeenEvent.listen(node.brokerCtx, handler).valueOr:
    await plugin.stop()
    return err(error)
  node.protocols.mixRlnListener = Opt.some(listener)
  node.subscriptionManager.subscribe(plugin.config.metadataTopic).isOkOr:
    await node.stopMixRln()
    return err(error)
  return ok()
