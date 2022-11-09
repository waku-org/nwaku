when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  chronicles,
  chronos,
  libp2p/protocols/pubsub
import
  ../../../protocol/waku_message,
  ../../message_cache

logScope: 
  topics = "waku node rest relay_api"

export message_cache


##### TopicCache

type TopicCacheResult*[T] = MessageCacheResult[T]

type TopicCache* = MessageCache[PubSubTopic]


##### Message handler

type TopicCacheMessageHandler* = Topichandler

proc messageHandler*(cache: TopicCache): TopicCacheMessageHandler =

  let handler = proc(pubsubTopic: string, data: seq[byte]): Future[void] {.async, closure.} =
    trace "PubsubTopic handler triggered", pubsubTopic=pubsubTopic

    # Add message to current cache
    let msg = WakuMessage.decode(data)
    if msg.isErr():
      debug "WakuMessage received but failed to decode", msg=msg, pubsubTopic=pubsubTopic
      # TODO: handle message decode failure
      return

    trace "WakuMessage received", msg=msg, pubsubTopic=pubsubTopic
    cache.addMessage(PubSubTopic(pubsubTopic), msg.get())
  
  handler