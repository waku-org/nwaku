import std/[tables, sequtils, options]

import waku/waku_core/topics, ../testlib/wakucore

proc `==`*(
    table: Table[pubsub_topic.NsPubsubTopic, seq[NsContentTopic]],
    other: array[0 .. 0, (string, seq[string])],
): bool =
  let otherTyped = other.map(
    proc(item: (string, seq[string])): (NsPubsubTopic, seq[NsContentTopic]) =
      let
        (pubsubTopic, contentTopics) = item
        nsPubsubTopic = NsPubsubTopic.parse(pubsubTopic).value()
        nsContentTopics = contentTopics.map(
          proc(contentTopic: string): NsContentTopic =
            NsContentTopic.parse(contentTopic).value()
        )
      return (nsPubsubTopic, nsContentTopics)
  )

  table == otherTyped.toTable()
