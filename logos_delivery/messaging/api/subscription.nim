## Messaging layer API — subscription operations.
import results, chronos

import logos_delivery/api/types
import logos_delivery/messaging/messaging_client
import logos_delivery/kernel/kernel_lifecycle
import logos_delivery/kernel/[ops/subscriptions]
proc subscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Future[Result[void, string]] {.async.} =
  ?self.checkApiAvailability()
  return self.kernel.subscribe(contentTopic)

proc unsubscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Result[void, string] =
  ?self.checkApiAvailability()
  return self.kernel.unsubscribe(contentTopic)
