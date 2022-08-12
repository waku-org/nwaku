{.push raises: [Defect].}

import 
  std/[tables, sequtils],
  chronicles
import
  ../waku_message,
  ./rpc

type
  ContentFilterHandler* = proc(msg: WakuMessage) {.gcsafe, closure, raises: [Defect].}

  Filter* = object
    pubSubTopic*: string
    contentFilters*: seq[ContentFilter]
    handler*: ContentFilterHandler

  Filters* = Table[string, Filter]


proc init*(T: type Filters): T =
  initTable[string, Filter]()

proc addContentFilters*(filters: var Filters, requestId: string, pubsubTopic: string, contentFilters: seq[ContentFilter], handler: ContentFilterHandler) {.gcsafe.}=
  filters[requestId] = Filter(
    pubSubTopic: pubsubTopic,
    contentFilters: contentFilters,
    handler: handler
  )

proc removeContentFilters*(filters: var Filters, contentFilters: seq[ContentFilter]) {.gcsafe.} =
  # Flatten all unsubscribe topics into single seq
  let unsubscribeTopics = contentFilters.mapIt(it.contentTopic)
  
  debug "unsubscribing", unsubscribeTopics=unsubscribeTopics

  var rIdToRemove: seq[string] = @[]
  for rId, f in filters.mpairs:
    # Iterate filter entries to remove matching content topics
  
    # make sure we delete the content filter
    # if no more topics are left
    f.contentFilters.keepIf(proc (cf: auto): bool = cf.contentTopic notin unsubscribeTopics)

    if f.contentFilters.len == 0:
      rIdToRemove.add(rId)

  # make sure we delete the filter entry
  # if no more content filters left
  for rId in rIdToRemove:
    filters.del(rId)
  
  debug "filters modified", filters=filters

proc notify*(filters: Filters, msg: WakuMessage, requestId: string) =
  for key, filter in filters.pairs:
    # We do this because the key for the filter is set to the requestId received from the filter protocol.
    # This means we do not need to check the content filter explicitly as all MessagePushs already contain
    # the requestId of the coresponding filter.
    if requestId != "" and requestId == key:
      filter.handler(msg)
      continue

    # TODO: In case of no topics we should either trigger here for all messages,
    # or we should not allow such filter to exist in the first place.
    for contentFilter in filter.contentFilters:
      if msg.contentTopic == contentFilter.contentTopic:
        filter.handler(msg)
        break
