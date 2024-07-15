import results
import ./recv_monitor, ./send_monitor, ../../waku_core

type DeliveryMonitor* = ref object
  sendMonitor*: SendMonitor
  recvMonitor*: RecvMonitor

  storePeer: RemotePeerInfo
    ## this is needed because the store nodes might not share the same history,
    ## until the sync protocol is fully tested: https://github.com/waku-org/pm/issues/162

proc new*(T: type DeliveryMonitor, storePeer: RemotePeerInfo): Result[T, string] =
  let sendMonitor = ?SendMonitor.new(storePeers)
  let recvMonitor = RecvMonitor.new()
  return ok(
    DeliveryMonitor(
      sendMonitor: sendMonitor, recvMonitor: recvMonitor, storePeers: storePeers
    )
  )

proc startDeliveryMonitor*(self: DeliveryMonitor) =
  self.sendMonitor.startSendMonitor()
  self.recvMonitor.startRecvMonitor()

proc stopDeliveryMonitor*(self: DeliveryMonitor) =
  self.sendMonitor.stopSendMonitor()
  self.recvMonitor.stopRecvMonitor()
