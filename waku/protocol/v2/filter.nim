import libp2p/protocols/pubsub/rpc/messages

import 
  tables

type 

  FilterMessageHandler* = proc(msg: Message) {.gcsafe, closure.}

  Filter* = object
    topics: seq[string] # @TODO TOPIC
    handler: FilterMessageHandler
    
  Filters* = Table[string, Filter]

proc init*(T: type Filter, topics: seq[string], handler: FilterMessageHandler): T =
  result = T(
    topics: topics,
    handler: handler
  )

proc containsMatch(lhs: seq[string], rhs: seq[string]): bool =
  for leftItem in lhs:
    for rightItem in rhs:
      if leftItem == rightItem:
        return true

proc notify*(filters: var Filters, msg: Message) {.gcsafe.} =
  for filter in filters.mvalues:
    # @TODO WILL NEED TO CHECK SUBTOPICS IN FUTURE FOR WAKU TOPICS NOT LIBP2P ONES
    if filter.topics.len > 0 and not filter.topics.containsMatch(msg.topicIDs):
      continue

    filter.handler(msg)
