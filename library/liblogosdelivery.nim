import std/atomics
import chronicles, chronos, chronos/threadsync, ffi
import
  logos_delivery/kernel/protocols/message,
  logos_delivery/kernel/protocols/topics/pubsub_topic,
  logos_delivery/kernel/protocols/relay/protocol,
  logos_delivery/kernel/health_monitor/topic_health,
  logos_delivery,
  logos_delivery/kernel/kernel_lifecycle,
  logos_delivery/kernel/kernel,
  ./events/json_message_event,
  ./declare_lib

################################################################################
## Include different APIs, i.e. all procs with {.ffi.} pragma

include
  ./logos_delivery_api/node_api,
  ./logos_delivery_api/messaging_api,
  ./logos_delivery_api/debug_api,
  ./logos_delivery_api/service_discovery_plugin_api,
  ./logos_delivery_api/sync_exports,
  ./kernel_api/peer_manager_api,
  ./kernel_api/discovery_api,
  ./kernel_api/debug_node_api,
  ./kernel_api/ping_api,
  ./kernel_api/protocols/relay_api,
  ./kernel_api/protocols/store_api,
  ./kernel_api/protocols/lightpush_api,
  ./kernel_api/protocols/mix_api,
  ./kernel_api/protocols/filter_api,
  ./channels_api/channel_api

# Node lifecycle (create / start / stop / destroy) is unified under the stable
# logosdelivery_* surface in ./logos_delivery_api/node_api. The former
# waku_new / waku_start / waku_stop / waku_destroy entry points were removed to
# avoid maintaining two parallel node-lifecycle APIs.

# Emits the dispatch wrappers, so it must stay the last FFI call here.
genBindings()
