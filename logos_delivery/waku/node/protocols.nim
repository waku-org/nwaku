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
    wakuArchive*: waku_archive.WakuArchive
    wakuStore*: store.WakuStore
    wakuStoreClient*: store_client.WakuStoreClient
    wakuStoreResume*: StoreResume
    wakuStoreReconciliation*: SyncReconciliation
    wakuStoreTransfer*: SyncTransfer
    wakuFilter*: waku_filter_v2.WakuFilter
    wakuFilterClient*: filter_client.WakuFilterClient
    rlnPlugin*: Opt[RlnPlugin]
    wakuLegacyLightPush*: WakuLegacyLightPush
    wakuLegacyLightpushClient*: WakuLegacyLightPushClient
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuMetadata*: WakuMetadata
    libp2pPing*: Ping
    legacyAppHandlers*: Table[PubsubTopic, WakuRelayHandler]
      ## Kernel API Relay appHandlers (if any)
    wakuMixRln*: ModuleRlnProtection
    wakuMixRlnListener*: Opt[MessageSeenEventListener]
    wakuMix*: WakuMix
    mixNodeResolution*: Future[void].Raising([CancelledError])
      ## The background lookup of the `dns4` mix node names; `nil` when none.
    mixNodeNames*: seq[MixNodeName]
      ## The names without an answer yet; `start` resumes them after a stop.
    relayReconnectFut*: Future[void]
