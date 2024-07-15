## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##

import std/[tables, sets, sequtils]
import chronos, chronicles
import ../../waku_core

const DelayExtra* = chronos.seconds(10)
  ## Additional security time to overlap the missing messages queries

type SubscrType = enum
  SPECIFIC_CONTENT_TOPICS
  ALL_CONTENT_TOPICS

type TopicInterest = object
  ## Helps to keep track of the previous requests that we made to monitor expected messages
  storePeer: RemotePeerInfo
  pubsubTopic: string
  contentTopics: seq[string]
  subscrType: SubscrType ## This may sound unnecessary but is interesting to be explicit
  lastChecked: chronos.Moment

type RecvMonitor* = ref object
  topicsInterest: Table[string, seq[TopicInterest]]
    ## Tracks message verification requests and when was the last time a
    ## pubsub topic was verified for missing messages
    ## The key contains pubsub-topics

  storePeers: seq[RemotePeerInfo]

proc new*(T: type RecvMonitor, storePeers: seq[RemotePeerInfo]): T =
  ## The storePeers parameter contains the seq of store nodes that will help to acquire
  ## any possible missed message
  return RecvMonitor(storePeers: storePeers)

proc setTopicsOfInterest*(
    self: RecvMonitor, pubsubTopic: string, contentTopics = newSeq[string]()
) =
  let subscrType =
    if contentTopics.len == 0: ALL_CONTENT_TOPICS else: SPECIFIC_CONTENT_TOPICS

  let lastChecked = Moment.now() - DelayExtra

  let newTopicOfInterest = self.storePeers.mapIt(
    TopicInterest(
      storePeer: it,
      pubsubTopic: pubsubTopic,
      contentTopics: contentTopics,
      subscrType: subscrType,
      lastChecked: lastChecked,
    )
  )

  ## Always override any possible previous value
  self.topicsInterest[pubsubTopic] = newTopicOfInterest

proc removeTopicsOfInterest*(
    self: RecvMonitor, pubsubTopic: string, contentTopics = newSeq[string]()
) =
  discard
