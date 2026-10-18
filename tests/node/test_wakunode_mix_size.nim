{.used.}

## The size limit of a mix send, against the real mix library.

import
  std/strutils,
  testutils/unittests,
  chronos,
  chronicles,
  results,
  brokers/broker_context,
  libp2p/[peerid, peerinfo, switch],
  libp2p_mix/curve25519
import
  logos_delivery/kernel/[
    kernel,
    protocols/protocols,
    net/bound_ports,
    api/mix,
    api/kernel_lifecycle,
    protocols/mix/protocol,
    api/publish,
    peer_manager/peer_manager,
    api/lightpush,
    protocols/lightpush/common,
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/message,
    base/peers,
    base/codecs,
    config/conf,
  ],
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, delivery_task, mix_processor],
  ../testlib/[futures, testasync, wakucore, mix_size_network, wakunodeconf]

proc senderConf(): WakuConf =
  var nodeConf = defaultTestWakuNodeConf()
  nodeConf.clusterId = Opt.some(DefaultClusterId)
  return nodeConf.toWakuConf().valueOr:
    raiseAssert error

proc newService(waku: Kernel, level: AnonymityLevel): SendService =
  ## Each accepted task runs through the scheduler.
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  let chain = setupSendProcessorChain(waku, level).expect("chain")
  let service = SendService
    .new(false, waku, manager, chain, level, retryInterval = chronos.hours(1))
    .expect("SendService.new")
  service.startSendService()
  return service

proc sizedTask(id: string, size: int): DeliveryTask =
  ## An admitted task whose lightpush request over mix has `size` bytes.
  const contentTopic = "/mix-size/1/probe/proto"
  for n in 0 .. size:
    let msg = fakeWakuMessage(payload = newSeq[byte](n), contentTopic = contentTopic)
    if mixLightpushSize(DefaultPubsubTopic, msg).size == size:
      return DeliveryTask(
        requestId: RequestId(id),
        pubsubTopic: DefaultPubsubTopic,
        msg: msg,
        msgHash: computeMessageHash(DefaultPubsubTopic, msg),
        state: DeliveryState.Entry,
        firstAdmittedTime: Opt.some(Moment.now()), # no budget and no proof
      )
  raiseAssert "no payload gives a request of " & $size & " bytes"

suite "Waku Mix - the size of a mix send":
  asyncTest "the largest message that fits goes over mix, and one more byte fails at once":
    let net = await startMixNodes()
    defer:
      await net.stop(@[])
    var waku: Kernel
    lockNewGlobalBrokerContext:
      waku = (await Kernel.new(senderConf())).expect("Kernel.new")
      let keys = generateKeyPair().expect("mix key pair")
      (await waku.mountMix(DefaultClusterId, keys.privateKey, net.infos)).isOkOr:
        raiseAssert "mountMix: " & $error
      (await waku.start()).expect("start")
    defer:
      discard await waku.stop()
    for node in net.nodes:
      await waku.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
    waku.peerManager.addServicePeer(
      net.exit.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )
    checkUntilTimeout:
      waku.mixReady()
      waku.selectMixLightpushPeer(DefaultPubsubTopic).isSome()

    var errors: seq[string]
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(event.error),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)
    let service = newService(waku, AnonymityLevel.Required)
    defer:
      await service.stopSendService()
    let limit = mixLightpushSize(DefaultPubsubTopic, fakeWakuMessage()).limit

    let tooLarge = sizedTask("one-byte-too-many", limit + 1)
    check service.enqueue(tooLarge).isOk()
    checkUntilTimeout:
      tooLarge.state == DeliveryState.FailedToDeliver
    check:
      tooLarge.state == DeliveryState.FailedToDeliver
      tooLarge.errorDesc.startsWith(MixTooLargeReason)
      tooLarge.tryCount == 0
    checkUntilTimeout:
      errors.len == 1
    check errors == @[tooLarge.errorDesc]

    let fits = sizedTask("largest-that-fits", limit)
    check service.enqueue(fits).isOk()
    checkUntilTimeout:
      fits.state == DeliveryState.SuccessfullyPropagated
    check:
      fits.state == DeliveryState.SuccessfullyPropagated
      fits.propagatedAnonymously
      errors.len == 1
