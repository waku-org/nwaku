{.push raises: [].}

import
  std/tables,
  chronos,
  results,
  libp2p/[multiaddress, protocols/ping],
  mix_rln_spam_protection/module_api
import
  logos_delivery/kernel/[
    common/topics/pubsub_topic,
    archive/archive,
    protocols/relay/protocol,
    protocols/store/protocol as store,
    protocols/store/client as store_client,
    protocols/store/resume,
    protocols/store_sync/reconciliation,
    protocols/store_sync/transfer,
    protocols/filter/protocol as filter,
    protocols/filter/client as filter_client,
    protocols/metadata/protocol,
    protocols/lightpush_legacy/client as legacy_ligntpuhs_client,
    protocols/lightpush_legacy/protocol,
    protocols/lightpush/client as ligntpuhs_client,
    protocols/lightpush/protocol,
    protocols/mix/protocol,
    rln/rln_plugin,
    events/kernel_events,
  ]
type
  MixNodeName* = tuple[entry: MixNodePubInfo, address: MultiAddress]

  Protocols* = ref object
    ## The libp2p protocols mounted on the node, apart from discovery.
    relay*: WakuRelay
    archive*: WakuArchive
    store*: store.WakuStore
    storeClient*: store_client.WakuStoreClient
    storeResume*: StoreResume
    storeReconciliation*: SyncReconciliation
    storeTransfer*: SyncTransfer
    filter*: filter.WakuFilter
    filterClient*: filter_client.WakuFilterClient
    rlnPlugin*: Opt[RlnPlugin]
    legacyLightPush*: WakuLegacyLightPush
    legacyLightPushClient*: WakuLegacyLightPushClient
    lightPush*: WakuLightPush
    lightPushClient*: WakuLightPushClient
    metadata*: WakuMetadata
    libp2pPing*: Ping
    legacyAppHandlers*: Table[PubsubTopic, WakuRelayHandler]
      ## Kernel API Relay appHandlers (if any)
    mixRln*: ModuleRlnProtection
    mixRlnListener*: Opt[MessageSeenEventListener]
    mix*: WakuMix
    mixNodeResolution*: Future[void].Raising([CancelledError])
      ## The background lookup of the `dns4` mix node names; `nil` when none.
    mixNodeNames*: seq[MixNodeName]
      ## The names without an answer yet; `start` resumes them after a stop.
    relayReconnectFut*: Future[void]
