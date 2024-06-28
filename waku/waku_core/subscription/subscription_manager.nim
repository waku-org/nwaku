{.push raises: [].}

import std/tables, stew/results, chronicles, chronos

import ./push_handler, ../topics, ../message

## Subscription manager
type SubscriptionManager* = object
  subscriptions: TableRef[(string, ContentTopic), FilterPushHandler]

proc init*(T: type SubscriptionManager): T =
  SubscriptionManager(
    subscriptions: newTable[(string, ContentTopic), FilterPushHandler]()
  )

proc clear*(m: var SubscriptionManager) =
  m.subscriptions.clear()

proc registerSubscription*(
    m: SubscriptionManager,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
    handler: FilterPushHandler,
) =
  try:
    # TODO: Handle over subscription surprises
    m.subscriptions[(pubsubTopic, contentTopic)] = handler
  except CatchableError:
    error "failed to register filter subscription", error = getCurrentExceptionMsg()

proc removeSubscription*(
    m: SubscriptionManager, pubsubTopic: PubsubTopic, contentTopic: ContentTopic
) =
  m.subscriptions.del((pubsubTopic, contentTopic))

proc notifySubscriptionHandler*(
    m: SubscriptionManager,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
    message: WakuMessage,
) =
  if not m.subscriptions.hasKey((pubsubTopic, contentTopic)):
    return

  try:
    let handler = m.subscriptions[(pubsubTopic, contentTopic)]
    asyncSpawn handler(pubsubTopic, message)
  except CatchableError:
    discard

proc getSubscriptionsCount*(m: SubscriptionManager): int =
  m.subscriptions.len()
