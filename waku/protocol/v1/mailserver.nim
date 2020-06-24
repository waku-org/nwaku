import
  eth/[p2p], 
  eth/p2p/rlpx_protocols/whisper/whisper_types,
  db_sqlite

type  
  MailServer* = object
    db*: DbConn

  Cursor = seq[byte]

  MailRequest* = object
    lower*: uint32 ## Unix timestamp; oldest requested envelope's creation time
    upper*: uint32 ## Unix timestamp; newest requested envelope's creation time
    bloom*: seq[byte] ## Bloom filter to apply on the envelopes
    limit*: uint32 ## Maximum amount of envelopes to return
    cursor*: Cursor ## Optional cursor

proc p2pRequestHandler*(server: MailServer, peer: Peer, envelope: Envelope) = 
  var symKey: SymKey
  let decoded = decode(envelope.data, symKey = some(symKey))
  if not decoded.isSome():
    # @TODO
    error "not some? lol"
    return

  var rlp = rlpFromBytes(decoded.get().payload)
  let request = rlp.read(MailRequest)

proc setupDB*(server: MailServer) =
  let db = open("mytest.db", "", "", "")

  # @TODO THIS PROBABLY DOES NOT BELONG HERE
  db.exec(sql"""CREATE TABLE envelopes IF NOT EXISTS (id BYTEA NOT NULL UNIQUE, data BYTEA NOT NULL, topic BYTEA NOT NULL, bloom BIT(512) NOT NULL);
    CREATE INDEX id_bloom_idx ON envelopes (id DESC, bloom);
    CREATE INDEX id_topic_idx ON envelopes (id DESC, topic);""")

  server.db = db

proc archive*(server: MailServer, message: Message) =
  var key: Bytes

  # In status go we have `B''::bit(512)` where I placed $4, let's see if it works this way though.
  server.db.exec(
    sql"INSERT INTO envelopes (id, data, topic, bloom) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING;",
    key, message.env, message.env.topic, message.bloom
  )
  # @TODO
  discard