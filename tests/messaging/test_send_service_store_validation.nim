{.used.}

import std/sequtils
import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/kernel,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/waku_store,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/api/store,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task],
  logos_delivery/api/events/messaging_client_events
import ../testlib/[futures, testasync, wakunodeconf, wakucore, wakunode]
import ../waku_store/store_utils

## Store-based reliability asks a store node for a propagated message's hash, in
## clear from this node's own address. It must never ask for a mixed message.

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc newTask(id: string): DeliveryTask =
  let msg = WakuMessage(
    contentTopic: "/test/1/store-validation/proto",
    payload: id.toBytes(),
    timestamp: 1_700_000_000_000_000_000,
  )
  let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
  return DeliveryTask(
    requestId: RequestId(id),
    pubsubTopic: pubsubTopic,
    msg: msg,
    msgHash: computeMessageHash(pubsubTopic, msg),
    state: DeliveryState.Entry,
  )

proc propagatedAt(id: string, time: Moment): DeliveryTask =
  ## A task that propagated at `time` and waits for a Store confirmation.
  let task = newTask(id)
  task.state = DeliveryState.SuccessfullyPropagated
  task.firstPropagatedTime = Opt.some(time)
  return task

suite "SendService - store validation and mix":
  var kernel {.threadvar.}: Kernel

  asyncSetup:
    kernel = (await Kernel.new(testConf())).expect("Kernel.new")

  asyncTeardown:
    await kernel.stop()

  proc service(reliability: bool): SendService =
    ## The policy under test never sends, so the plain chain is enough.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let chain = setupSendProcessorChain(kernel, AnonymityLevel.None).expect("chain")
    return SendService.new(reliability, kernel, manager, chain).expect("SendService.new")

  proc propagatedTask(overMix: bool, ephemeral = false): DeliveryTask =
    let task = propagatedAt("t", Moment.now())
    task.msg.ephemeral = ephemeral
    task.propagatedAnonymously = overMix
    return task

  asyncTest "the store client is mounted even on a node that serves no store":
    ## `checkStoreForMessages` is `preferP2PReliability and isStoreMounted()`,
    ## and every node mounts the store client, so reliability alone decides.
    check kernel.isStoreMounted()

  asyncTest "a plainly propagated message is confirmed against a store node":
    check service(reliability = true).awaitsStoreValidation(
      propagatedTask(overMix = false)
    )

  asyncTest "a message that went out over mix is never confirmed against a store node":
    ## The query would carry its hash, in clear, from this node's own address.
    check not service(reliability = true).awaitsStoreValidation(
      propagatedTask(overMix = true)
    )

  asyncTest "an ephemeral message is not confirmed either, mixed or not":
    let reliable = service(reliability = true)
    check:
      not reliable.awaitsStoreValidation(
        propagatedTask(overMix = false, ephemeral = true)
      )
      not reliable.awaitsStoreValidation(
        propagatedTask(overMix = true, ephemeral = true)
      )

  asyncTest "nothing is confirmed when reliability is off":
    check not service(reliability = false).awaitsStoreValidation(
      propagatedTask(overMix = false)
    )

  asyncTest "a task that has not propagated is not confirmed yet":
    let task = propagatedTask(overMix = false)
    task.state = DeliveryState.NextRoundRetry
    check not service(reliability = true).awaitsStoreValidation(task)

## A scripted processor sets the outcome that a real processor would, so these
## tests drive the completion events with no live mixnet.
type ScriptedProc = ref object of BaseSendProcessor
  overMix: bool
  calls: int
  retryCalls: seq[int] ## Calls, counted from 1, that leave the task for a retry.

method process(self: ScriptedProc, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  if self.calls in self.retryCalls:
    task.state = DeliveryState.NextRoundRetry
    return
  task.state = DeliveryState.SuccessfullyPropagated
  task.propagatedAnonymously = self.overMix
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

const FastLoop = chronos.milliseconds(10)
  ## The loop interval of a test service. It keeps each wait for a loop short.

proc reliableService(
    kernel: Kernel, processor: BaseSendProcessor, maxValidationAge = DeliveryWindow
): SendService =
  ## A service with Store-based reliability on and fast loops.
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  return SendService
    .new(
      true,
      kernel,
      manager,
      processor,
      maxValidationAge = maxValidationAge,
      retryInterval = FastLoop,
    )
    .expect("SendService.new")

type SendEvent {.pure.} = enum
  Propagated
  Sent
  Failed

type SendEventLog = ref object
  ## Records the request ids of send events and wakes the tests that wait for one.
  brokerCtx: BrokerContext
  ids: array[SendEvent, seq[RequestId]]
  changed: AsyncEvent
  propagatedListener: MessagePropagatedEventListener
  sentListener: MessageSentEventListener
  errorListener: MessageErrorEventListener

proc record(log: SendEventLog, event: SendEvent, id: RequestId) =
  log.ids[event].add(id)
  log.changed.fire()

proc newSendEventLog(brokerCtx: BrokerContext): SendEventLog =
  let log = SendEventLog(brokerCtx: brokerCtx, changed: newAsyncEvent())
  let onPropagated = proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
    log.record(SendEvent.Propagated, event.requestId)
  let onSent = proc(event: MessageSentEvent) {.async: (raises: []).} =
    log.record(SendEvent.Sent, event.requestId)
  let onError = proc(event: MessageErrorEvent) {.async: (raises: []).} =
    log.record(SendEvent.Failed, event.requestId)
  log.propagatedListener =
    MessagePropagatedEvent.listen(brokerCtx, onPropagated).expect("listen propagated")
  log.sentListener = MessageSentEvent.listen(brokerCtx, onSent).expect("listen sent")
  log.errorListener =
    MessageErrorEvent.listen(brokerCtx, onError).expect("listen error")
  return log

proc teardown(log: SendEventLog) {.async.} =
  await MessagePropagatedEvent.dropListener(log.brokerCtx, log.propagatedListener)
  await MessageSentEvent.dropListener(log.brokerCtx, log.sentListener)
  await MessageErrorEvent.dropListener(log.brokerCtx, log.errorListener)

proc waitEvent(
    log: SendEventLog,
    event: SendEvent,
    task: DeliveryTask,
    timeout = chronos.seconds(5),
): Future[bool] {.async.} =
  ## Waits until `event` is recorded for `task`, or the timeout expires.
  let deadline = Moment.now() + timeout
  while true:
    log.changed.clear()
    if task.requestId in log.ids[event]:
      return true
    let remaining = deadline - Moment.now()
    if remaining <= ZeroDuration or not await log.changed.wait().withTimeout(remaining):
      return task.requestId in log.ids[event]

suite "SendService - mix completion":
  var kernel {.threadvar.}: Kernel

  asyncSetup:
    kernel = (await Kernel.new(testConf())).expect("Kernel.new")

  asyncTeardown:
    await kernel.stop()

  proc countSent(counter: EventCounter): MessageSentEventListener =
    return MessageSentEvent
      .listen(
        kernel.brokerCtx,
        proc(e: MessageSentEvent) {.async: (raises: []).} =
          counter.inc(),
      )
      .expect("listen")

  asyncTest "a mixed send reports MessageSent once":
    ## With reliability on, the exit's reply completes the send.
    let sent = EventCounter()
    let listener = countSent(sent)
    defer:
      await MessageSentEvent.dropListener(kernel.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(true, kernel, manager, ScriptedProc(overMix: true), AnonymityLevel.Preferred)
      .expect("SendService.new") # reliability = on
    let task = newTask("mixed-once")

    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await sent.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await sent.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)

  asyncTest "reliability off: a mixed send ends the same as a plain one (no MessageSent)":
    ## With store reliability off, a plain and a mixed send both end at
    ## `MessagePropagated`.
    let sent = EventCounter()
    let listener = countSent(sent)
    defer:
      await MessageSentEvent.dropListener(kernel.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, kernel, manager, ScriptedProc(overMix: true), AnonymityLevel.Preferred)
      .expect("SendService.new") # reliability = false
    let task = newTask("mixed-no-reliability")
    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeout:
      task.propagatedEventEmitted
    check not await sent.waitCount(1).withTimeout(FUTURE_TIMEOUT_SHORT)

suite "SendService - Store validation window":
  var kernel {.threadvar.}: Kernel
  var log {.threadvar.}: SendEventLog

  asyncSetup:
    kernel = (await Kernel.new(testConf())).expect("Kernel.new")
    log = newSendEventLog(kernel.brokerCtx)

  asyncTeardown:
    await log.teardown()
    await kernel.stop()

  asyncTest "the time while the service is stopped does not count against the window":
    ## The task propagates, then the service stops for longer than the window.
    ## After the restart the task still waits for its Store confirmation.
    let window = chronos.milliseconds(500)
    let service = reliableService(kernel, ScriptedProc(), maxValidationAge = window)
    let task = newTask("restart")
    check service.enqueue(task).isOk()
    service.startSendService()
    check await log.waitEvent(SendEvent.Propagated, task)
    await service.stopSendService()
    check:
      task.storeAnswer.isNil()
      task.storeValidationWaited < window
    await sleepAsync(window * 2)

    service.startSendService()
    defer:
      await service.stopSendService()
    check not await log.waitEvent(SendEvent.Failed, task, chronos.milliseconds(100))
    checkUntilTimeout:
      not task.storeAnswer.isNil()
    task.storeAnswer.complete()
    check await log.waitEvent(SendEvent.Sent, task)
    check:
      task.state == DeliveryState.SuccessfullyValidated
      log.ids[SendEvent.Failed].len == 0

  asyncTest "the waits of a task add up to the window":
    ## A task that already waited most of the window fails soon after a restart.
    let window = chronos.milliseconds(500)
    let service = reliableService(kernel, ScriptedProc(), maxValidationAge = window)
    let task = newTask("adds-up")
    task.storeValidationWaited = window - chronos.milliseconds(50)
    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitEvent(SendEvent.Failed, task)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.storeValidationWaited >= window

suite "SendService - Store validation batches":
  var kernel {.threadvar.}: Kernel
  var service {.threadvar.}: SendService

  asyncSetup:
    kernel = (await Kernel.new(testConf())).expect("Kernel.new")
    service = reliableService(kernel, ScriptedProc())

  asyncTeardown:
    await kernel.stop()

  asyncTest "a batch holds one Store page, and the tasks that waited longest come first":
    let now = Moment.now()
    var tasks =
      toSeq(0 ..< 250).mapIt(propagatedAt("t" & $it, now - chronos.seconds(10)))

    # A task asked less than ArchiveTime ago waits for a later batch.
    for (first, size) in [(0, 100), (100, 100), (200, 50)]:
      let batch = service.nextStoreValidationBatch(tasks, now)
      check:
        batch.len == size
        batch[0].requestId == RequestId("t" & $first)
      for task in batch:
        task.lastStoreQueryTime = Opt.some(now)
    check service.nextStoreValidationBatch(tasks, now).len == 0

    # A task never asked comes before the tasks asked since it propagated. A task
    # that propagated after that query comes after them. Ties keep cache order.
    tasks.add(propagatedAt("t250", now - chronos.seconds(10)))
    tasks.add(propagatedAt("t251", now + chronos.seconds(1)))
    let later = service.nextStoreValidationBatch(tasks, now + chronos.seconds(5))
    check:
      later.len == 100
      later[0].requestId == RequestId("t250")
      later[1].requestId == RequestId("t0")
      later[99].requestId == RequestId("t98")

  asyncTest "a task that propagated within ArchiveTime or over mix is not in a batch":
    let now = Moment.now()
    let young = propagatedAt("young", now - chronos.seconds(1))
    let mixed = propagatedAt("mixed", now - chronos.seconds(10))
    mixed.propagatedAnonymously = true
    let plain = propagatedAt("plain", now - chronos.seconds(10))
    check service.nextStoreValidationBatch(@[young, mixed, plain], now) == @[plain]

suite "SendService - Store validation loop":
  ## The Store node answers only after `allowAnswer` completes, with the hashes listed in
  ## `storedHashes`. It mounts metadata so the peer manager accepts its cluster.
  var kernel {.threadvar.}: Kernel
  var storeNode {.threadvar.}: Kernel
  var allowAnswer {.threadvar.}: Future[void]
  var queryStarted {.threadvar.}: Future[void]
  var answered {.threadvar.}: AsyncEvent
  var storedHashes {.threadvar.}: seq[WakuMessageHash]
  var log {.threadvar.}: SendEventLog

  proc delayedStoreHandler(
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    if not queryStarted.finished():
      queryStarted.complete()
    await allowAnswer
    var resp = StoreQueryResponse(
      requestId: req.requestId, statusCode: uint32(StatusCode.SUCCESS)
    )
    for hash in req.messageHashes:
      if hash in storedHashes:
        resp.messages.add(WakuMessageKeyValue(messageHash: hash))
    answered.fire()
    return ok(resp)

  asyncSetup:
    kernel = (await Kernel.new(testConf())).expect("Kernel.new")
    (await kernel.start()).isOkOr:
      raiseAssert "waku.start: " & error
    allowAnswer = newFuture[void]("allow-answer")
    queryStarted = newFuture[void]("query started")
    answered = newAsyncEvent()
    storedHashes = @[]
    log = newSendEventLog(kernel.brokerCtx)
    storeNode = newTestWakuNode(generateSecp256k1Key())
    storeNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & error
    discard await newTestWakuStore(storeNode.switch, delayedStoreHandler)
    await storeNode.startProtocols()
    kernel.peerManager.addServicePeer(
      storeNode.peerInfo.toRemotePeerInfo(), WakuStoreCodec
    )

  asyncTeardown:
    if not allowAnswer.finished():
      allowAnswer.complete()
    await log.teardown()
    await storeNode.stop()
    await kernel.stop()

  proc startedService(processor: BaseSendProcessor = ScriptedProc()): SendService =
    let service = reliableService(kernel, processor)
    service.startSendService()
    return service

  proc sendAged(
      service: SendService, id: string, stored = true
  ): Future[DeliveryTask] {.async.} =
    ## Sends a task, waits for the report of its propagation, and makes it old
    ## enough for the next Store query. Unless `stored` is false, the Store lists
    ## its hash.
    let task = newTask(id)
    check:
      service.enqueue(task).isOk()
      await log.waitEvent(SendEvent.Propagated, task)
    if stored:
      storedHashes.add(task.msgHash)
    task.firstPropagatedTime = Opt.some(Moment.now() - chronos.seconds(10))
    return task

  asyncTest "a slow Store query does not delay a retry":
    ## A's Store query stays pending while B's failed send is retried.
    let processor = ScriptedProc(retryCalls: @[2])
    let service = startedService(processor)
    defer:
      await service.stopSendService()

    let taskA = await service.sendAged("slow-store-a")
    check:
      taskA.state == DeliveryState.SuccessfullyPropagated
      await queryStarted.withTimeout(chronos.seconds(5))

    let taskB = newTask("slow-store-b")
    check:
      service.enqueue(taskB).isOk()
      await log.waitEvent(SendEvent.Propagated, taskB)
      kernel.peerManager.hasActiveStoreRequest(storeNode.peerInfo.peerId)
      processor.calls == 3

    allowAnswer.complete()
    check:
      await log.waitEvent(SendEvent.Sent, taskA)
      taskA.state == DeliveryState.SuccessfullyValidated

  asyncTest "an answer for a task whose validation window ended is ignored":
    ## A's confirmation arrives after its validation window ended and the service
    ## failed A.
    let service = reliableService(kernel, ScriptedProc(), chronos.seconds(2))
    service.startSendService()
    defer:
      await service.stopSendService()

    let taskA = await service.sendAged("expire-in-flight")
    check await queryStarted.withTimeout(chronos.seconds(5))
    check await log.waitEvent(SendEvent.Failed, taskA)

    # C's confirmation comes from a later query, so A's answer was handled first.
    allowAnswer.complete()
    check await answered.wait().withTimeout(chronos.seconds(5))
    let taskC = await service.sendAged("confirmed-after")
    check:
      await log.waitEvent(SendEvent.Sent, taskC)
      taskA.state == DeliveryState.FailedToDeliver
      taskA.requestId notin log.ids[SendEvent.Sent]

  asyncTest "stopping the service ends a pending Store query":
    let service = startedService()
    discard await service.sendAged("stop-in-flight")
    check await queryStarted.withTimeout(chronos.seconds(5))

    let stopping = service.stopSendService()
    check:
      await stopping.join().withTimeout(chronos.seconds(3))
      not kernel.peerManager.hasActiveStoreRequest(storeNode.peerInfo.peerId)

  asyncTest "a restart during the Store wait sends nothing again, and the Store confirms the send":
    let processor = ScriptedProc()
    let service = startedService(processor)
    let task = await service.sendAged("restart-in-store-wait")
    check await queryStarted.withTimeout(chronos.seconds(5))

    await service.stopSendService()
    # Old enough for the first Store query after the restart.
    task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
    service.startSendService()
    defer:
      await service.stopSendService()
    allowAnswer.complete()
    check:
      await log.waitEvent(SendEvent.Sent, task)
      processor.calls == 1
      log.ids[SendEvent.Propagated].countIt(it == task.requestId) == 1

  asyncTest "a message the Store does not report yet is asked again, never sent again":
    let processor = ScriptedProc()
    let service = startedService(processor)
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    # The first answer does not list the hash.
    let task = await service.sendAged("not-yet-stored", stored = false)
    check await answered.wait().withTimeout(chronos.seconds(5))

    # The next answer lists it. Make the task old enough for that query.
    storedHashes.add(task.msgHash)
    task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
    check:
      await log.waitEvent(SendEvent.Sent, task)
      task.state == DeliveryState.SuccessfullyValidated
      processor.calls == 1
