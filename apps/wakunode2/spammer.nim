when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronos,
  chronicles,
  stew/[byteutils, results],
  std/times,
  libp2p/protocols/pubsub/gossipsub,
  strutils

import
  ../../waku/factory/waku,
  ../../waku/factory/external_config,
  ../../waku/waku_core,
  ../../waku/waku_relay,
  ../../waku/node/waku_node,
  ../../waku/node/peer_manager/peer_manager,
  ../../waku/waku_rln_relay/rln_relay,
  ../../tests/waku_rln_relay/rln/waku_rln_relay_utils

proc send(
    waku: Waku, contentTopic: ContentTopic
): Future[Result[void, string]] {.async.} =
  var ephemeral = true

  var message = WakuMessage(
    payload: toBytes("Hello World!" & intToStr(int(getTime().toUnix()))),
    contentTopic: contentTopic,
    #      meta: metaBytes,
    version: 2,
    timestamp: getNanosecondTime(getTime().toUnixFloat()),
    ephemeral: ephemeral,
  )

  let rlnRes =
    waku.node.wakuRlnRelay.unsafeAppendRLNProof(message, float64(getTime().toUnix()))
  if rlnRes.isOk:
    let pubRes = await waku.node.publish(none(PubsubTopic), message)
    if pubRes.isErr():
      error "failed to publish", msg = pubRes.error
      return err(pubRes.error)
  else:
    error "failed to append RLNProof", err = rlnRes.error
    return err(rlnRes.error)

  return ok()

proc runSpammer*(
    waku: Waku, conf: WakuNodeConf, contentTopic: ContentTopic = "/spammer/0/test/plain"
) {.async.} =
  if not conf.enable:
    return

  if not conf.rlnRelay:
    error "RLN not configured!"
    quit(QuitFailure)

  var gotPeers = false
  while not gotPeers:
    var (inRelayPeers, outRelayPeers) =
      waku.node.peerManager.connectedPeers(WakuRelayCodec)

    var numPeers = len(inRelayPeers) + len(outRelayPeers)
    if numPeers > 0:
      gotPeers = true
    info "Waiting for peers", numPeers = numPeers
    await sleepAsync(1000)
  #var rate = int(float(1000) / float(conf.msgRate))
  #var delayBetweenMsg =
  #  float(conf.rlnEpochSizeSec * 1000) /
  #  (float(conf.rlnRelayUserMessageLimit) * conf.msgRateMultiplier)

  info "Sending message with delay", delay = conf.delay

  while true:
    var start = getTime().toUnix()

    (await send(waku, contentTopic)).isOkOr:
      error "Failed to publish", err = error

    #echo await (waku.node.isReady())
    var current = getTime().toUnix()
    var tillNextMsg = int(int64(conf.delay) - (current - start))
    info "Published messages", sleep = tillNextMsg

    await sleepAsync(tillNextMsg)
