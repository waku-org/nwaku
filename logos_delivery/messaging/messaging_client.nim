## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import std/[sequtils, times], results, chronos, chronicles
import
  logos_delivery/kernel/[
    kernel_lifecycle,
    ops/publish,
    ops/health,
    health_monitor/node_health_monitor,
    base/health/protocol_health,
    peer_manager/online_monitor,
    base/health/health_status,
    base/health/connection_status,
    config/conf_builder/conf_builder,
    persistency/persistency,
  ],
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/api/messaging_client_api,
  logos_delivery/messaging/delivery_service/recv_service/recv_service,
  logos_delivery/messaging/delivery_service/send_service/send_service,
  logos_delivery/messaging/delivery_service/send_service/delivery_task,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager
export messaging_client_api, messaging_conf

type MessagingClient* = ref object
  brokerCtx*: BrokerContext
  kernel*: Kernel ## The Waku kernel this layer drives; read by `messaging/api/*`.
  sendService*: SendService
  recvService*: RecvService
  persistencyJob*: persistency.Job
  started*: bool

const
  MaxParkedAgeSecLimit = 7'u * 24 * 3600
  SendQueueCapacityLimit = 1_000_000'u

proc rlnQuotaProvider(kernel: Kernel): QuotaProvider =
  ## Sources the rate limit manager's epoch budget from RLN. The closure
  ## queries `waku` on each admission, so a node whose RLN mounts after
  ## construction upgrades from the local fallback automatically.
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    let res =
      try:
        await kernel.rlnEpochQuota(uint64(getTime().toUnix()))
      except CatchableError:
        return Opt.none(EpochQuota)
    let quota = res.valueOr:
      return Opt.none(EpochQuota)
    return Opt.some(quota)

proc requireMixReady*(
    status: ConnectionStatus, protocols: seq[ProtocolHealth]
): ConnectionStatus {.gcsafe, raises: [].} =
  ## `Required` has no plain fallback, so without mix nothing can be sent.
  if protocols.anyIt(it.protocol == $MixProtocol and it.health == HealthStatus.READY):
    return status
  return ConnectionStatus.Disconnected

proc new*(
    T: type MessagingClient, conf: MessagingClientConf, kernel: Kernel
): Result[T, string] =
  ## The messaging layer chains onto Waku: it drives the underlying Waku kernel
  ## for transport while exposing its own send/recv API.
  let reliability = conf.reliabilityEnabled.get(DefaultP2pReliability)
  let anonymityLevel = conf.anonymityLevel.get(AnonymityLevel.None)
  let rateLimitConfig = conf.rateLimitConfig()
  let rateLimitManager =
    ?RateLimitManager.new(rateLimitConfig, rlnQuotaProvider(kernel))
  let maxParkedAgeSec = conf.maxParkedAgeSec.get(uint(DefaultMaxParkedAge.seconds()))
  if maxParkedAgeSec notin 1'u .. MaxParkedAgeSecLimit:
    return err("maxParkedAgeSec must be between 1 and " & $MaxParkedAgeSecLimit)
  let sendQueueCapacity = conf.sendQueueCapacity.get(uint(DefaultSendQueueCapacity))
  if sendQueueCapacity notin 1'u .. SendQueueCapacityLimit:
    return err("sendQueueCapacity must be between 1 and " & $SendQueueCapacityLimit)
  let sendProcessor = setupSendProcessorChain(kernel, anonymityLevel).valueOr:
    return err("failed to setup SendProcessorChain: " & error)
  let sendService = ?SendService.new(
    reliability,
    kernel,
    rateLimitManager,
    sendProcessor,
    anonymityLevel = anonymityLevel,
    maxParkedAge = seconds(int64(maxParkedAgeSec)),
    sendQueueCapacity = int(sendQueueCapacity),
  )
  let backfill = ?BackfillState.init(conf)
  let recvService = RecvService.new(kernel, backfill)

  if anonymityLevel == AnonymityLevel.Required:
    kernel.setConnectionStatusAdjuster(requireMixReady)
  # Log the values that the preset, the flags and the defaults give.
  info "Messaging API settings",
    reliability = reliability,
    anonymityLevel = anonymityLevel,
    rateLimitEnabled = rateLimitConfig.enabled,
    rateLimitEpochPeriodSec = rateLimitConfig.epochPeriodSec,
    rateLimitMessagesPerEpoch = rateLimitConfig.messagesPerEpoch,
    maxParkedAgeSec = maxParkedAgeSec,
    sendQueueCapacity = sendQueueCapacity,
    backfillEnabled = backfill.enabled,
    backfillRequestTimeout = backfill.queryTimeout

  return ok(
    T(
      kernel: kernel,
      sendService: sendService,
      recvService: recvService,
      brokerCtx: kernel.brokerCtx,
    )
  )

proc checkApiAvailability*(self: MessagingClient): Result[void, string] =
  ## Shared guard for the api operation module.
  if self.isNil():
    return err("MessagingClient is not initialized")

  return ok()
