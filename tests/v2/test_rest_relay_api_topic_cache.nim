{.used.}

import
  std/tables,
  stew/byteutils,
  stew/shims/net,
  chronicles,
  testutils/unittests,
  presto,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/rest/relay/topic_cache


proc fakeWakuMessage(payload = toBytes("TEST"), contentTopic = "test"): WakuMessage = 
  WakuMessage(
    payload: payload,
    contentTopic: contentTopic,
    version: 1,
    timestamp: 2022
  )


suite "TopicCache":
  test "subscribe to topic": 
    ## Given
    let testTopic = "test-pubsub-topic"
    let cache = TopicCache.init()

    ## When
    cache.subscribe(testTopic)

    ## Then
    check:
      cache.isSubscribed(testTopic)


  test "unsubscribe from topic": 
    ## Given
    let testTopic = "test-pubsub-topic"
    let cache = TopicCache.init()

    # Init cache content
    cache.subscribe(testTopic)

    ## When
    cache.unsubscribe(testTopic)

    ## Then
    check:
      not cache.isSubscribed(testTopic)
  

  test "get messages of a subscribed topic":
    ## Given
    let testTopic = "test-pubsub-topic"
    let testMessage = fakeWakuMessage()
    let cache = TopicCache.init() 

    # Init cache content
    cache.subscribe(testTopic)
    cache.addMessage(testTopic, testMessage)

    ## When
    let res = cache.getMessages(testTopic)

    ## Then
    check:
      res.isOk()
      res.get() == @[testMessage]


  test "get messages with clean flag shoud clear the messages cache":
    ## Given
    let testTopic = "test-pubsub-topic"
    let testMessage = fakeWakuMessage()
    let cache = TopicCache.init() 

    # Init cache content
    cache.subscribe(testTopic)
    cache.addMessage(testTopic, testMessage)

    ## When
    var res = cache.getMessages(testTopic, clear=true)
    require(res.isOk())

    res = cache.getMessages(testTopic)

    ## Then
    check:
      res.isOk()
      res.get().len == 0
    

  test "get messages of a non-subscribed topic":
    ## Given
    let testTopic = "test-pubsub-topic"
    let cache = TopicCache.init()

    ## When
    let res = cache.getMessages(testTopic)

    ## Then
    check:
      res.isErr()
      res.error() == "Not subscribed to topic"


  test "add messages to subscribed topic":
    ## Given
    let testTopic = "test-pubsub-topic"
    let testMessage = fakeWakuMessage()
    let cache = TopicCache.init()

    cache.subscribe(testTopic)

    ## When 
    cache.addMessage(testTopic, testMessage)

    ## Then
    let messages = cache.getMessages(testTopic).tryGet()
    check:
      messages == @[testMessage]


  test "add messages to non-subscribed topic":
    ## Given
    let testTopic = "test-pubsub-topic"
    let testMessage = fakeWakuMessage()
    let cache = TopicCache.init()

    ## When 
    cache.addMessage(testTopic, testMessage)

    ## Then
    let res = cache.getMessages(testTopic)
    check:
     res.isErr()
     res.error() == "Not subscribed to topic"

  
  test "add messages beyond the capacity":
    ## Given
    let testTopic = "test-pubsub-topic"
    let testMessages = @[
      fakeWakuMessage(toBytes("MSG-1")),
      fakeWakuMessage(toBytes("MSG-2")),
      fakeWakuMessage(toBytes("MSG-3"))
    ]

    let cache = TopicCache.init(conf=TopicCacheConfig(capacity: 2))
    cache.subscribe(testTopic)

    ## When 
    for msg in testMessages:
      cache.addMessage(testTopic, msg)

    ## Then
    let messages = cache.getMessages(testTopic).tryGet() 
    check:
      messages == testMessages[1..2]
