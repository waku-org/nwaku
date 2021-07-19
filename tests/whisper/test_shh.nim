#
#                 Ethereum P2P
#              (c) Copyright 2018-2021
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

{.used.}

import
  std/[sequtils, options, unittest, tables],
  nimcrypto/hash,
  eth/[keys, rlp],
  ../../waku/whisper/whisper_types as whisper

let rng = newRng()

suite "Whisper payload":
  test "should roundtrip without keys":
    let payload = Payload(payload: @[byte 0, 1, 2])
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().src.isNone()
      decoded.get().padding.get().len == 251 # 256 -1 -1 -3

  test "should roundtrip with symmetric encryption":
    var symKey: SymKey
    let payload = Payload(symKey: some(symKey), payload: @[byte 0, 1, 2])
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get(), symKey = some(symKey))
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().src.isNone()
      decoded.get().padding.get().len == 251 # 256 -1 -1 -3

  test "should roundtrip with signature":
    let privKey = PrivateKey.random(rng[])

    let payload = Payload(src: some(privKey), payload: @[byte 0, 1, 2])
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      privKey.toPublicKey() == decoded.get().src.get()
      decoded.get().padding.get().len == 186 # 256 -1 -1 -3 -65

  test "should roundtrip with asymmetric encryption":
    let privKey = PrivateKey.random(rng[])

    let payload = Payload(dst: some(privKey.toPublicKey()),
      payload: @[byte 0, 1, 2])
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get(), dst = some(privKey))
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().src.isNone()
      decoded.get().padding.get().len == 251 # 256 -1 -1 -3

  test "should return specified bloom":
    # Geth test: https://github.com/ethersphere/go-ethereum/blob/d3441ebb563439bac0837d70591f92e2c6080303/whisper/whisperv6/whisper_test.go#L834
    let top0 = [byte 0, 0, 255, 6]
    var x: Bloom
    x[0] = byte 1
    x[32] = byte 1
    x[^1] = byte 128
    check @(top0.topicBloom) == @x

suite "Whisper payload padding":
  test "should do max padding":
    let payload = Payload(payload: repeat(byte 1, 254))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().padding.isSome()
      decoded.get().padding.get().len == 256 # as dataLen == 256

  test "should do max padding with signature":
    let privKey = PrivateKey.random(rng[])

    let payload = Payload(src: some(privKey), payload: repeat(byte 1, 189))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      privKey.toPublicKey() == decoded.get().src.get()
      decoded.get().padding.isSome()
      decoded.get().padding.get().len == 256 # as dataLen == 256

  test "should do min padding":
    let payload = Payload(payload: repeat(byte 1, 253))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().padding.isSome()
      decoded.get().padding.get().len == 1 # as dataLen == 255

  test "should do min padding with signature":
    let privKey = PrivateKey.random(rng[])

    let payload = Payload(src: some(privKey), payload: repeat(byte 1, 188))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      privKey.toPublicKey() == decoded.get().src.get()
      decoded.get().padding.isSome()
      decoded.get().padding.get().len == 1 # as dataLen == 255

  test "should roundtrip custom padding":
    let payload = Payload(payload: repeat(byte 1, 10),
                          padding: some(repeat(byte 2, 100)))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().padding.isSome()
      payload.padding.get() == decoded.get().padding.get()

  test "should roundtrip custom 0 padding":
    let padding: seq[byte] = @[]
    let payload = Payload(payload: repeat(byte 1, 10),
                          padding: some(padding))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      decoded.get().padding.isNone()

  test "should roundtrip custom padding with signature":
    let privKey = PrivateKey.random(rng[])
    let payload = Payload(src: some(privKey), payload: repeat(byte 1, 10),
                          padding: some(repeat(byte 2, 100)))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      privKey.toPublicKey() == decoded.get().src.get()
      decoded.get().padding.isSome()
      payload.padding.get() == decoded.get().padding.get()

  test "should roundtrip custom 0 padding with signature":
    let padding: seq[byte] = @[]
    let privKey = PrivateKey.random(rng[])
    let payload = Payload(src: some(privKey), payload: repeat(byte 1, 10),
                          padding: some(padding))
    let encoded = whisper.encode(rng[], payload)

    let decoded = whisper.decode(encoded.get())
    check:
      decoded.isSome()
      payload.payload == decoded.get().payload
      privKey.toPublicKey() == decoded.get().src.get()
      decoded.get().padding.isNone()

# example from https://github.com/paritytech/parity-ethereum/blob/93e1040d07e385d1219d00af71c46c720b0a1acf/whisper/src/message.rs#L439
let
  env0 = Envelope(
    expiry:100000, ttl: 30, topic: [byte 0, 0, 0, 0],
    data: repeat(byte 9, 256), nonce: 1010101)
  env1 = Envelope(
    expiry:100000, ttl: 30, topic: [byte 0, 0, 0, 0],
    data: repeat(byte 9, 256), nonce: 1010102)
  env2 = Envelope(
    expiry:100000, ttl: 30, topic: [byte 0, 0, 0, 0],
    data: repeat(byte 9, 256), nonce: 1010103)

suite "Whisper envelope":

  proc hashAndPow(env: Envelope): (string, float64) =
    # This is the current implementation of go-ethereum
    let size = env.toShortRlp().len().uint32
    # This is our current implementation in `whisper_protocol.nim`
    # let size = env.len().uint32
    # This is the EIP-627 specification
    # let size = env.toRlp().len().uint32
    let hash = env.calcPowHash()
    ($hash, calcPow(size, env.ttl, hash))

  test "PoW calculation leading zeroes tests":
    # Test values from Parity, in message.rs
    let testHashes = [
      # 256 leading zeroes
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      # 255 leading zeroes
      "0x0000000000000000000000000000000000000000000000000000000000000001",
      # no leading zeroes
      "0xff00000000000000000000000000000000000000000000000000000000000000"
    ]
    check:
      calcPow(1, 1, Hash.fromHex(testHashes[0])) ==
        115792089237316200000000000000000000000000000000000000000000000000000000000000.0
      calcPow(1, 1, Hash.fromHex(testHashes[1])) ==
        57896044618658100000000000000000000000000000000000000000000000000000000000000.0
      calcPow(1, 1, Hash.fromHex(testHashes[2])) == 1.0

    # Test values from go-ethereum whisperv6 in envelope_test
    var env = Envelope(ttl: 1, data: @[byte 0xde, 0xad, 0xbe, 0xef])
    # PoW calculation with no leading zeroes
    env.nonce = 100000
    check hashAndPoW(env) == ("A788E02A95BFC673709E97CA81E39CA903BAD5638D3388964C51EB64952172D6",
                              0.07692307692307693)
    # PoW calculation with 8 leading zeroes
    env.nonce = 276
    check hashAndPoW(env) == ("00E2374C6353C243E4073E209A7F2ACB2506522AF318B3B78CF9A88310A2A11C",
                              19.692307692307693)

suite "Whisper queue":
  test "should throw out lower proof-of-work item when full":
    var queue = initQueue(1)

    let msg0 = initMessage(env0)
    let msg1 = initMessage(env1)

    discard queue.add(msg0)
    discard queue.add(msg1)

    check:
      queue.items.len() == 1
      queue.items[0].env.nonce ==
        (if msg0.pow > msg1.pow: msg0.env.nonce else: msg1.env.nonce)

  test "should not throw out messages as long as there is capacity":
    var queue = initQueue(2)

    check:
      queue.add(initMessage(env0)) == true
      queue.add(initMessage(env1)) == true

      queue.items.len() == 2

  test "check if order of queue is by decreasing PoW":
    var queue = initQueue(3)

    let msg0 = initMessage(env0)
    let msg1 = initMessage(env1)
    let msg2 = initMessage(env2)

    discard queue.add(msg0)
    discard queue.add(msg1)
    discard queue.add(msg2)

    check:
      queue.items.len() == 3
      queue.items[0].pow > queue.items[1].pow and
        queue.items[1].pow > queue.items[2].pow

  test "check field order against expected rlp order":
    check rlp.encode(env0) ==
      rlp.encodeList(env0.expiry, env0.ttl, env0.topic, env0.data, env0.nonce)

# To test filters we do not care if the msg is valid or allowed
proc prepFilterTestMsg(pubKey = none[PublicKey](), symKey = none[SymKey](),
                       src = none[PrivateKey](), topic: Topic,
                       padding = none[seq[byte]]()): Message =
    let payload = Payload(dst: pubKey, symKey: symKey, src: src,
                          payload: @[byte 0, 1, 2], padding: padding)
    let encoded = whisper.encode(rng[], payload)
    let env = Envelope(expiry: 1, ttl: 1, topic: topic, data: encoded.get(),
                       nonce: 0)
    result = initMessage(env)

suite "Whisper filter":
  test "should notify filter on message with symmetric encryption":
    var symKey: SymKey
    let topic = [byte 0, 0, 0, 0]
    let msg = prepFilterTestMsg(symKey = some(symKey), topic = topic)

    var filters = initTable[string, Filter]()
    let filter = initFilter(symKey = some(symKey), topics = @[topic])
    let filterId = subscribeFilter(rng[], filters, filter)

    notify(filters, msg)

    let messages = filters.getFilterMessages(filterId)
    check:
      messages.len == 1
      messages[0].decoded.src.isNone()
      messages[0].dst.isNone()

  test "should notify filter on message with asymmetric encryption":
    let privKey = PrivateKey.random(rng[])
    let topic = [byte 0, 0, 0, 0]
    let msg = prepFilterTestMsg(pubKey = some(privKey.toPublicKey()),
                                topic = topic)

    var filters = initTable[string, Filter]()
    let filter = initFilter(privateKey = some(privKey), topics = @[topic])
    let filterId = subscribeFilter(rng[], filters, filter)

    notify(filters, msg)

    let messages = filters.getFilterMessages(filterId)
    check:
      messages.len == 1
      messages[0].decoded.src.isNone()
      messages[0].dst.isSome()

  test "should notify filter on message with signature":
    let privKey = PrivateKey.random(rng[])
    let topic = [byte 0, 0, 0, 0]
    let msg = prepFilterTestMsg(src = some(privKey), topic = topic)

    var filters = initTable[string, Filter]()
    let filter = initFilter(src = some(privKey.toPublicKey()),
                           topics = @[topic])
    let filterId = subscribeFilter(rng[], filters, filter)

    notify(filters, msg)

    let messages = filters.getFilterMessages(filterId)
    check:
      messages.len == 1
      messages[0].decoded.src.isSome()
      messages[0].dst.isNone()

  test "test notify of filter against PoW requirement":
    let topic = [byte 0, 0, 0, 0]
    let padding = some(repeat(byte 0, 251))
    # this message has a PoW of 0.02962962962962963, number should be updated
    # in case PoW algorithm changes or contents of padding, payload, topic, etc.
    # update: now with NON rlp encoded envelope size the PoW of this message is
    # 0.014492753623188406
    let msg = prepFilterTestMsg(topic = topic, padding = padding)

    var filters = initTable[string, Filter]()
    let
      filterId1 = subscribeFilter(rng[], filters,
                    initFilter(topics = @[topic], powReq = 0.014492753623188406))
      filterId2 = subscribeFilter(rng[], filters,
                    initFilter(topics = @[topic], powReq = 0.014492753623188407))

    notify(filters, msg)

    check:
      filters.getFilterMessages(filterId1).len == 1
      filters.getFilterMessages(filterId2).len == 0

  test "test notify of filter on message with certain topic":
    let
      topic1 = [byte 0xAB, 0x12, 0xCD, 0x34]
      topic2 = [byte 0, 0, 0, 0]

    let msg = prepFilterTestMsg(topic = topic1)

    var filters = initTable[string, Filter]()
    let
      filterId1 = subscribeFilter(rng[], filters, initFilter(topics = @[topic1]))
      filterId2 = subscribeFilter(rng[], filters, initFilter(topics = @[topic2]))

    notify(filters, msg)

    check:
      filters.getFilterMessages(filterId1).len == 1
      filters.getFilterMessages(filterId2).len == 0
