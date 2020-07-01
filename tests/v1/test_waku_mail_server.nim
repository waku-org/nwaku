import
  unittest, chronos, tables, sequtils, times,
  eth/[p2p, async_utils], eth/p2p/peer_pool,
  ../../waku/protocol/v1/[waku_protocol, waku_mail, waku_mail_server],
  ./test_helpers

proc newMailServer(): MailServer =
  result = MailServer()
  result.setupDB() 

suite "Waku Mail Server":

  var server = newMailServer()

  test "should allow setting and retreiving a message":

    let ttl = 1'u32
    let topic = [byte 1, 2, 3, 4]
    let env = Envelope(expiry:epochTime().uint32 + ttl, ttl: ttl, topic: topic,
                       data: repeat(byte 9, 256), nonce: 0)
    check env.valid()

    let msg = initMessage(env)
    server.archive(msg)

    let res = server.getEnvelope(dbkey(msg.env.expiry - msg.env.ttl, msg.env.topic, msg.hash))

    check res == env
