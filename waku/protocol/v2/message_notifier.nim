import
  std/tables,
  libp2p/protocols/pubsub/rpc/messages

# The Message Notification system is a method to notify various protocols
# running on a node when a new message was received.
#
# Protocols can subscribe to messages of specific topics, then when one is received
# The notification handler function will be called.

type
  MessageNotificationHandler* = proc(msg: Message) {.gcsafe, closure.}

  MessageNotificationSubscription* = object
    topics: seq[string] # @TODO TOPIC
    handler: MessageNotificationHandler
    
  MessageNotificationSubscriptions* = Table[string, MessageNotificationSubscription]

proc subscribe*(subscriptions: var MessageNotificationSubscriptions, name: string, subscription: MessageNotificationSubscription) =
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

proc notify*(subscriptions: var MessageNotificationSubscriptions, msg: Message) {.gcsafe.} =
  for subscription in subscriptions.mvalues:
    # @TODO WILL NEED TO CHECK SUBTOPICS IN FUTURE FOR WAKU TOPICS NOT LIBP2P ONES
    if subscription.topics.len > 0 and not subscription.topics.containsMatch(msg.topicIDs):
      continue

    subscription.handler(msg)
