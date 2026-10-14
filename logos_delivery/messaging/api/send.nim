## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/api/subscriptions
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc enqueueSend(
    self: MessagingClient, envelope: MessageEnvelope
): Result[RequestId, string] =
  ## The body of `send`. It is not async, so it cannot suspend.
  ?self.checkApiAvailability()
  # A full send queue gets no subscribe. `enqueue` refuses the send.
  if not self.sendService.isFull():
    let isSubbed = self.waku.isSubscribed(envelope.contentTopic).valueOr(false)
    if not isSubbed:
      debug "Auto-subscribing to topic on send", contentTopic = envelope.contentTopic
      self.waku.subscribe(envelope.contentTopic).isOkOr:
        error "Failed to auto-subscribe", error = error
        return err("Failed to auto-subscribe before sending: " & error)

  let requestId = RequestId.new(self.waku.rng)

  let deliveryTask = DeliveryTask.new(requestId, envelope, self.waku.brokerCtx).valueOr:
    return err("MessagingClient.send: Failed to create delivery task: " & error)

  return self.sendService.enqueue(deliveryTask)

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ## Subscribes to the content topic, queues the message and returns its
  ## request id. It never suspends, so the caller gets the id before any event
  ## of the request, also over the FFI.
  return self.enqueueSend(envelope)
