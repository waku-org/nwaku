import ../waku_relay/protocol

type AppCallbacks* = ref object
  relayHandler*: WakuRelayHandler
