import
  chronos,
  std/tables,
  libp2p/protocols/pubsub/rpc/messages

# The Message Notification system is a method to notify various protocols
# running on a node when a new message was received.
#
# Protocols can subscribe to messages of specific topics, then when one is received
# The notification handler function will be called.

type
  MessageNotificationHandler* = proc(msg: Message): Future[void] {.gcsafe, closure.}

  MessageNotificationSubscription* = object
    topics: seq[string] # @TODO TOPIC
    handler: MessageNotificationHandler

  MessageNotificationSubscriptions* = TableRef[string, MessageNotificationSubscription]

proc subscribe*(subscriptions: MessageNotificationSubscriptions, name: string, subscription: MessageNotificationSubscription) =
  subscriptions.add(name, subscription)

proc init*(T: type MessageNotificationSubscription, topics: seq[string], handler: MessageNotificationHandler): T =
  result = T(
    topics: topics,
    handler: handler
  )

proc containsMatch(lhs: seq[string], rhs: seq[string]): bool =
  for leftItem in lhs:
    if leftItem in rhs:
      return true

  return false

proc notify*(subscriptions: MessageNotificationSubscriptions, msg: Message) {.async, gcsafe.} =
  var futures = newSeq[Future[void]]()

  for subscription in subscriptions.mvalues:
    # @TODO WILL NEED TO CHECK SUBTOPICS IN FUTURE FOR WAKU TOPICS NOT LIBP2P ONES
    if subscription.topics.len > 0 and not subscription.topics.containsMatch(msg.topicIDs):
      continue

    futures.add(subscription.handler(msg))

  await allFutures(futures)
