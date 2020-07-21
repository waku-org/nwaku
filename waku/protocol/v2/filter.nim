import 
  tables

type 

  FilterMessageHandler* = proc(msg: Data) {.gcsafe, closure.}

  Filter* = object
    topics: seq[string] # @TODO TOPIC
    handler: FilterMessageHandler
    
  Filters* = Table[string, Filter]

proc init*(T: type Filter, topics: seq[string], handler: FilterMessageHandler): T =
  result = T(
    topics: topics,
    handler: handler
  )

proc notify*(filters: var Filters, topic: string, msg: seq[byte]) {.gcsafe.} =
  for filter in filters.mvalues:
    if filter.topics.len > 0 && topic notin filter.topics:
      continue

    filter.handler(msg)