{.push raises: [].}

import
  std/tables,
  chronos,
  results,
  libp2p/[multiaddress, protocols/ping],
  libp2p_mix,
  mix_rln_spam_protection/module_api
import
  logos_delivery/waku/[
    waku_core,
    waku_relay,
    waku_archive,
    waku_store/protocol as store,
    waku_store/client as store_client,
    waku_store/resume,
    waku_store_sync,
    waku_filter_v2,
    waku_filter_v2/client as filter_client,
    waku_metadata,
    waku_lightpush_legacy/client as legacy_ligntpuhs_client,
    waku_lightpush_legacy as legacy_lightpush_protocol,
    waku_lightpush/client as ligntpuhs_client,
    waku_lightpush as lightpush_protocol,
    rln/rln_plugin,
    waku_mix,
  ],
  logos_delivery/api/events/kernel_events

type
  MixNodeName* = tuple[entry: MixNodePubInfo, address: MultiAddress]

  Protocols* = object
    ## The libp2p protocols mounted on the node, apart from discovery.
    relay*: WakuRelay
    archive*: waku_archive.WakuArchive
    store*: store.WakuStore
    storeClient*: store_client.WakuStoreClient
    storeResume*: StoreResume
    storeReconciliation*: SyncReconciliation
    storeTransfer*: SyncTransfer
    filter*: waku_filter_v2.WakuFilter
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
