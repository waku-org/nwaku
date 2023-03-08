## Waku Filter client for subscribing and receiving filtered messages

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  chronos,
  libp2p/protocols/protocol
import
  ../../node/peer_manager,
  ../waku_message,
  ./common,
  ./protocol_metrics,
  ./rpc_codec,
  ./rpc

logScope:
  topics = "waku filter client"

type
  MessagePushHandler* = proc(pubsubTopic: PubsubTopic, message: WakuMessage) {.gcsafe, closure.}
  WakuFilterClient* = ref object of LPProtocol
    messagePushHandler: MessagePushHandler
    peerManager: PeerManager

proc initProtocolHandler(wfc: WakuFilterClient) =

  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(MaxPushSize)

    let decodeRes = MessagePush.decode(buf)
    if decodeRes.isErr():
      error "Failed to decode message push", peerId=conn.peerId
      waku_filter_errors.inc(labelValues = [decodeRpcFailure])
      return

    let messagePush = decodeRes.value #TODO: toAPI() split here
    trace "Received message push", peerId=conn.peerId, messagePush

    wfc.messagePushHandler(messagePush.pubsubTopic, messagePush.wakuMessage)

    # Protocol specifies no response for now
    return

  wfc.handler = handler
  wfc.codec = WakuFilterPushCodec

proc new*(T: type WakuFilterClient,
          messagePushHandler: MessagePushHandler,
          peerManager: PeerManager): T =

  let wfc = WakuFilterClient(
    messagePushHandler: messagePushHandler,
    peerManager: peerManager
  )
  wfc.initProtocolHandler()
  wfc
