{.used.}

import
  stew/[results, byteutils],
  testutils/unittests,
  chronicles
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/message_cache


proc fakeWakuMessage(payload = toBytes("TEST"), contentTopic = "test"): WakuMessage = 
  WakuMessage(
    payload: payload,
    contentTopic: contentTopic,
    version: 1,
    timestamp: 2022
  )

type PubsubTopicString = string

type TestMessageCache = MessageCache[(PubsubTopicString, ContentTopic)]


suite "MessageCache":
  test "subscribe to topic": 
    ## Given
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let cache = TestMessageCache.init()

    ## When
    cache.subscribe(testTopic)

    ## Then
    check:
      cache.isSubscribed(testTopic)


  test "unsubscribe from topic": 
    ## Given
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let cache = TestMessageCache.init()

    # Init cache content
    cache.subscribe(testTopic)

    ## When
    cache.unsubscribe(testTopic)

    ## Then
    check:
      not cache.isSubscribed(testTopic)
  

  test "get messages of a subscribed topic":
    ## Given
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let testMessage = fakeWakuMessage()
    let cache = TestMessageCache.init() 

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
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let testMessage = fakeWakuMessage()
    let cache = TestMessageCache.init() 

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
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let cache = TestMessageCache.init()

    ## When
    let res = cache.getMessages(testTopic)

    ## Then
    check:
      res.isErr()
      res.error() == "Not subscribed to topic"


  test "add messages to subscribed topic":
    ## Given
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let testMessage = fakeWakuMessage()
    let cache = TestMessageCache.init()

    cache.subscribe(testTopic)

    ## When 
    cache.addMessage(testTopic, testMessage)

    ## Then
    let messages = cache.getMessages(testTopic).tryGet()
    check:
      messages == @[testMessage]


  test "add messages to non-subscribed topic":
    ## Given
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let testMessage = fakeWakuMessage()
    let cache = TestMessageCache.init()

    ## When 
    cache.addMessage(testTopic, testMessage)

    ## Then
    let res = cache.getMessages(testTopic)
    check:
     res.isErr()
     res.error() == "Not subscribed to topic"

  
  test "add messages beyond the capacity":
    ## Given
    let testTopic = ("test-pubsub-topic", ContentTopic("test-content-topic"))
    let testMessages = @[
      fakeWakuMessage(toBytes("MSG-1")),
      fakeWakuMessage(toBytes("MSG-2")),
      fakeWakuMessage(toBytes("MSG-3"))
    ]

    let cache = TestMessageCache.init(capacity = 2)
    cache.subscribe(testTopic)

    ## When 
    for msg in testMessages:
      cache.addMessage(testTopic, msg)

    ## Then
    let messages = cache.getMessages(testTopic).tryGet() 
    check:
      messages == testMessages[1..2]
