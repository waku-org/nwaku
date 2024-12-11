import ../waku_relay/protocol

type WakuCallbacks* = ref object
  onReceivedMessage*: WakuRelayHandler
