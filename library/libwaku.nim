{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libwaku.so".}

import std/[json, atomics, strformat, options, atomics, macros]
import chronicles, chronos, chronos/threadsync, ffi
import
  waku/factory/waku,
  waku/common/base64,
  waku/waku_core/message/message,
  waku/node/waku_node,
  waku/node/peer_manager,
  waku/waku_core/topics/pubsub_topic,
  waku/waku_core/subscription/push_handler,
  waku/waku_relay,
  ./events/json_message_event,
  ./events/json_topic_health_change_event,
  ./events/json_connection_change_event,
  ./waku_thread_requests/node_lifecycle_request,
  ./waku_thread_requests/peer_manager_request,
  ./waku_thread_requests/protocols/relay_request,
  ./waku_thread_requests/protocols/store_request,
  ./waku_thread_requests/protocols/lightpush_request,
  ./waku_thread_requests/protocols/filter_request,
  ./waku_thread_requests/debug_node_request,
  ./waku_thread_requests/discovery_request,
  ./waku_thread_requests/ping_request,
  ../waku/factory/app_callbacks

################################################################################
### Wrapper around the waku node
################################################################################

################################################################################
### Not-exported components

declareLibrary("waku")

### End of not-exported components
################################################################################

################################################################################
### Exported procs

proc waku_new(
    configJson: cstring, callback: FFICallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  ## Creates a new instance of the WakuNode.
  if isNil(callback):
    echo "error: missing callback in waku_new"
    return nil

  ## Create the Waku thread that will keep waiting for req from the main thread.
  var ctx = ffi_context.createFFIContext(Waku).valueOr:
    let msg = "Error in createWakuContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  proc onReceivedMessage(ctx: ptr FFIContext): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  proc onTopicHealthChange(ctx: ptr FFIContext): TopicHealthChangeHandler =
    return proc(pubsubTopic: PubsubTopic, topicHealth: TopicHealth) {.async.} =
      callEventCallback(ctx, "onTopicHealthChange"):
        $JsonTopicHealthChangeEvent.new(pubsubTopic, topicHealth)

  proc onConnectionChange(ctx: ptr FFIContext): ConnectionChangeHandler =
    return proc(peerId: PeerId, peerEvent: PeerEventKind) {.async.} =
      callEventCallback(ctx, "onConnectionChange"):
        $JsonConnectionChangeEvent.new($peerId, peerEvent)

  let appCallbacks = AppCallbacks(
    relayHandler: onReceivedMessage(ctx),
    topicHealthChangeHandler: onTopicHealthChange(ctx),
    connectionChangeHandler: onConnectionChange(ctx),
  )

  ffi_context.sendRequestToFFIThread(
    ctx, CreateNodeRequest.ffiNewReq(callback, userData, configJson, appCallbacks)
  ).isOkOr:
    let msg = "error in sendRequestToFFIThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  return ctx

proc waku_destroy(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  ffi_context.destroyFFIContext(ctx).isOkOr:
    let msg = "libwaku error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK, nil, 0, userData)

  return RET_OK

proc waku_version(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetWakuVersionReq.processReq()

proc waku_content_topic(
    ctx: ptr FFIContext,
    appName: cstring,
    appVersion: cuint,
    contentTopicName: cstring,
    encoding: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

  initializeLibrary()
  checkParams(ctx, callback, userData)
  BuildContentTopicReq.processReq(appName, appVersion, contentTopicName, encoding)

proc waku_pubsub_topic(
    ctx: ptr FFIContext, topicName: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding

  initializeLibrary()
  checkParams(ctx, callback, userData)
  BuildPubsubTopicReq.processReq(topicName)

proc waku_default_pubsub_topic(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic

  initializeLibrary()
  checkParams(ctx, callback, userData)
  FetchPubsubTopicRequest.processReq()

proc waku_relay_publish(
    ctx: ptr FFIContext,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    timeoutMs: cuint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms
  initializeLibrary()
  checkParams(ctx, callback, userData)
  PublishRelayMsgReq.processReq(pubsubTopic, jsonWakuMessage, timeoutMs)

proc waku_start(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  StartNodeReq.processReq()

proc waku_stop(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  StopNodeReq.processReq()

proc waku_relay_subscribe(
    ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  proc onReceivedMessage(ctx: ptr FFIContext): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  var cb = onReceivedMessage(ctx)
  SubscribeReq.processReq(pubsubTopic, WakuRelayHandler(cb))

proc waku_relay_add_protected_shard(
    ctx: ptr FFIContext,
    clusterId: cint,
    shardId: cint,
    publicKey: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  AddProtectedShardReq.processReq(clusterId, shardId, publicKey)

proc waku_relay_unsubscribe(
    ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  UnsubscribeReq.processReq(pubsubTopic)

proc waku_relay_get_num_connected_peers(
    ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetNumConnectedPeersReq.processReq(pubSubTopic)

proc waku_relay_get_connected_peers(
    ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetConnectedPeersReq.processReq(pubSubTopic)

proc waku_relay_get_num_peers_in_mesh(
    ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetNumPeersInMeshReq.processReq(pubSubTopic)

proc waku_relay_get_peers_in_mesh(
    ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetPeersInMeshReq.processReq(pubSubTopic)

proc waku_filter_subscribe(
    ctx: ptr FFIContext,
    pubSubTopic: cstring,
    contentTopics: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  proc onReceivedMessage(ctx: ptr FFIContext): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  FilterSubscribeReq.processReq(
    pubsubTopic, contentTopics, FilterPushHandler(onReceivedMessage(ctx))
  )

proc waku_filter_unsubscribe(
    ctx: ptr FFIContext,
    pubSubTopic: cstring,
    contentTopics: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  FilterUnsubscribeReq.processReq(pubsubTopic, contentTopics)

proc waku_filter_unsubscribe_all(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  FilterUnsubscribeAllReq.processReq()

proc waku_lightpush_publish(
    ctx: ptr FFIContext,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  PublishLightpushMsgReq.processReq(pubsubTopic, jsonWakuMessage)

proc waku_connect(
    ctx: ptr FFIContext,
    peerMultiAddr: cstring,
    timeoutMs: cuint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  ConnectToReq.processReq(peerMultiAddr, timeoutMs)

proc waku_disconnect_peer_by_id(
    ctx: ptr FFIContext, peerId: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  DisconnectPeerByIdReq.processReq(peerId)

proc waku_disconnect_all_peers(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  DisconnectAllPeersReq.processReq()

proc waku_dial_peer(
    ctx: ptr FFIContext,
    peerMultiAddr: cstring,
    protocol: cstring,
    timeoutMs: cuint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  DialPeerReq.processReq(peerMultiAddr, protocol, timeoutMs)

proc waku_dial_peer_by_id(
    ctx: ptr FFIContext,
    peerId: cstring,
    protocol: cstring,
    timeoutMs: cuint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  DialPeerByIdReq.processReq(peerId, protocol, timeoutMs)

proc waku_get_peerids_from_peerstore(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetPeerIdsFromPeerStoreReq.processReq()

proc waku_get_connected_peers_info(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetConnectedPeersInfoReq.processReq()

proc waku_get_connected_peers(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetConnectedPeersReq.processReq()

proc waku_get_peerids_by_protocol(
    ctx: ptr FFIContext, protocol: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetConnectedPeerIdsByProtocolReq.processReq(protocol)

proc waku_store_query(
    ctx: ptr FFIContext,
    jsonQuery: cstring,
    peerAddr: cstring,
    timeoutMs: cint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  StoreQueryReq.processReq(jsonQuery, peerAddr, timeoutMs)

proc waku_listen_addresses(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetListenAddressesReq.processReq()

proc waku_dns_discovery(
    ctx: ptr FFIContext,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetBootstrapnodesReq.processReq(enrTreeUrl, nameDnsServer, timeoutMs)

proc waku_discv5_update_bootnodes(
    ctx: ptr FFIContext, bootnodes: cstring, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ## Updates the bootnode list used for discovering new peers via DiscoveryV5
  ## bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
  initializeLibrary()
  checkParams(ctx, callback, userData)
  UpdateDiscv5BootNodesReq.processReq(bootnodes)

proc waku_get_my_enr(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetMyEnrReq.processReq()

proc waku_get_my_peerid(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetMyPeerIdReq.processReq()

proc waku_get_metrics(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  GetMetricsReq.processReq()

proc waku_start_discv5(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  StartDiscv5Req.processReq()

proc waku_stop_discv5(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  StopDiscv5Req.processReq()

proc waku_peer_exchange_request(
    ctx: ptr FFIContext, numPeers: uint64, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  PeerExchangeReq.processReq(numPeers)

proc waku_ping_peer(
    ctx: ptr FFIContext,
    peerAddr: cstring,
    timeoutMs: cuint,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  PingReq.processReq(peerAddr, timeoutMs)

proc waku_is_online(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)
  IsOnlineReq.processReq()

# ### End of exported procs
# ################################################################################
