import
  unittest, chronos, tables, sequtils, times, os,
  eth/[p2p, async_utils], eth/p2p/peer_pool,
  ../../waku/protocol/v1/[waku_protocol, waku_mail, waku_mail_server],
  ./test_helpers

suite "Waku Mail Server":

  var server: MailServer

  setup:
    server = MailServer()
    server.setupDB() 

  teardown:
    removeFile("/tmp/msdb.db")

  test "should allow setting and retreiving a message":
    let ttl = 1'u32
    let topic = [byte 1, 2, 3, 4]
    let env = Envelope(expiry: epochTime().uint32 + ttl, ttl: ttl, topic: topic,
                       data: repeat(byte 9, 256), nonce: 0)
    check env.valid()

    let msg = initMessage(env)
    server.archive(msg)

    let res = server.getEnvelope(dbkey(msg.env.expiry - msg.env.ttl, msg.env.topic, msg.hash))

    check res == env

  test "should allow retreiving messages by topic":
    let ttl = 1'u32
    let topic = [byte 1, 2, 3, 4]
    let topic2 = [byte 4, 3, 2, 1]

    let topics = [topic, topic2]

    var exp: uint32

    for i in countup(1, 10):

      for t in topics:
        let env = Envelope(expiry: epochTime().uint32 + ttl, ttl: ttl, topic: t,
                            data: repeat(byte i, 256), nonce: 0)
        check env.valid()

        let msg = initMessage(env)
        server.archive(msg)

        exp = env.expiry

    let req = MailRequest(
      lower: 0,
      upper: exp + 30,
      bloom: @[],
      limit: 2,
      cursor: @[],
      topics: @[topic]
    )

    let res = server.getEnvelopes(req)

    check:
      len(res) == 2
    
    for e in res:
      check:
        e.topic == topic
