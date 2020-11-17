#
#                   Waku
#              (c) Copyright 2020
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)
{.used.}

import
  std/[sequtils, options, unittest, times],
  ../../waku/v1/protocol/waku_protocol

suite "Waku envelope validation":
  test "should validate and allow envelope according to config":
    let ttl = 1'u32
    let topic = [byte 1, 2, 3, 4]
    let config = WakuConfig(powRequirement: 0, bloom: some(topic.topicBloom()),
                            isLightNode: false, maxMsgSize: defaultMaxMsgSize)

    let env = Envelope(expiry:epochTime().uint32 + ttl, ttl: ttl, topic: topic,
                       data: repeat(byte 9, 256), nonce: 0)
    check env.valid()

    let msg = initMessage(env)
    check msg.allowed(config)

  test "should invalidate envelope due to ttl 0":
    let ttl = 0'u32
    let topic = [byte 1, 2, 3, 4]

    let env = Envelope(expiry:epochTime().uint32 + ttl, ttl: ttl, topic: topic,
                       data: repeat(byte 9, 256), nonce: 0)
    check env.valid() == false

  test "should invalidate envelope due to expired":
    let ttl = 1'u32
    let topic = [byte 1, 2, 3, 4]

    let env = Envelope(expiry:epochTime().uint32, ttl: ttl, topic: topic,
                       data: repeat(byte 9, 256), nonce: 0)
    check env.valid() == false

  test "should invalidate envelope due to in the future":
    let ttl = 1'u32
    let topic = [byte 1, 2, 3, 4]

    # there is currently a 2 second tolerance, hence the + 3
    let env = Envelope(expiry:epochTime().uint32 + ttl + 3, ttl: ttl,
                       topic: topic, data: repeat(byte 9, 256), nonce: 0)
    check env.valid() == false

  test "should not allow envelope due to bloom filter":
    let topic = [byte 1, 2, 3, 4]
    let wrongTopic = [byte 9, 8, 7, 6]
    let config = WakuConfig(powRequirement: 0,
                            bloom: some(wrongTopic.topicBloom()),
                            isLightNode: false, maxMsgSize: defaultMaxMsgSize)

    let env = Envelope(expiry:100000 , ttl: 30, topic: topic,
                        data: repeat(byte 9, 256), nonce: 0)

    let msg = initMessage(env)
    check msg.allowed(config) == false
