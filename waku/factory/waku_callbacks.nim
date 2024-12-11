import ../waku_relay/protocol

type WakuCallbacks* = ref object
  relayHandler*: WakuRelayHandler
