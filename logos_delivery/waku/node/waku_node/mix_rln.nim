{.push raises: [].}
import chronos, chronicles, results
import mix_rln_spam_protection/module_api
import logos_delivery/api/events/kernel_events
import
  logos_delivery/waku/
    [waku_core, node/waku_node, node/subscription_manager, rln/rln_plugin]
import ./[relay, lightpush]

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
  if node.protocols.wakuMixRln.isNil():
    return
  if node.protocols.wakuMixRlnListener.isSome():
    await MessageSeenEvent.dropListener(node.brokerCtx, node.protocols.wakuMixRlnListener.get())
  node.protocols.wakuMixRlnListener = Opt.none(MessageSeenEventListener)
  await node.protocols.wakuMixRln.stop()

proc startMixRln*(
    node: Kernel
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  if node.protocols.wakuMixRln.isNil():
    return err("Mix RLN is not configured")
  if node.protocols.rlnPlugin.isNone():
    return err("Mix RLN coordination requires Relay RLN")
  let plugin = node.protocols.wakuMixRln
  plugin.setPublishCallback(
    proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
      return await node.publishMetadata(topic, data)
  )
  (await plugin.start()).isOkOr:
    return err("Failed to start Mix RLN plugin: " & $error)
  if node.protocols.wakuMixRlnListener.isSome():
    return ok()
  let handler = proc(event: MessageSeenEvent): Future[void] {.async: (raises: []).} =
    if event.message.contentTopic == plugin.config.metadataTopic:
      plugin.handleProofMetadata(event.message.payload).isOkOr:
        debug "Rejected Mix coordination metadata", error
  let listener = MessageSeenEvent.listen(node.brokerCtx, handler).valueOr:
    await plugin.stop()
    return err(error)
  node.protocols.wakuMixRlnListener = Opt.some(listener)
  node.protocols.subscriptionManager.subscribe(plugin.config.metadataTopic).isOkOr:
    await node.stopMixRln()
    return err(error)
  return ok()
