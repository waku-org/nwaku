import
  eth/[p2p], 
  eth/p2p/rlpx_protocols/whisper/whisper_types,
  db_sqlite,
  sequtils, strformat,
  stew/[byteutils, endians2]

const
  MAILSERVER_DATABASE: string = "msdb.db"

type  
  MailServer* = ref object
    db*: DbConn

  Cursor* = seq[byte]

  DBKey* = seq[byte]

  MailRequest* = object
    lower*: uint32 ## Unix timestamp; oldest requested envelope's creation time
    upper*: uint32 ## Unix timestamp; newest requested envelope's creation time
    bloom*: seq[byte] ## Bloom filter to apply on the envelopes
    limit*: uint32 ## Maximum amount of envelopes to return
    cursor*: Cursor ## Optional cursor

proc dbkey(timestamp: uint32, topic: Topic, hash: Hash): DBKey =
  result = concat(@(timestamp.toBytesBE()), @topic, @(hash.data))

proc query(server: MailServer, request: MailRequest): seq[Row] =
  discard

func toBitString(bloom: seq[byte]): string =
  for n in bloom:
    result &= &"{n:08b}"

proc toEnvelope(str: string): Envelope =
  var rlp = rlpFromBytes(str.toBytes())
  result = rlp.read(Envelope)

proc getEnvelopes*(server: MailServer, request: MailRequest): seq[Envelope] =
  let rows = server.query(request)

  for row in rows:
    result.add(row[0].toEnvelope())

proc setupDB*(server: MailServer) =
  let db = open(MAILSERVER_DATABASE, "", "", "")

  # @TODO THIS PROBABLY DOES NOT BELONG HERE
  db.exec(sql"""CREATE TABLE envelopes IF NOT EXISTS (id BYTEA NOT NULL UNIQUE, data BYTEA NOT NULL, topic BYTEA NOT NULL, bloom BIT(512) NOT NULL);
    CREATE INDEX id_bloom_idx ON envelopes (id DESC, bloom);
    CREATE INDEX id_topic_idx ON envelopes (id DESC, topic);""")

  server.db = db
  
proc prune*(server: MailServer, time: uint32) =
  var emptyTopic: Topic = [byte 0, 0, 0, 0]
  var emptyHash: Hash

  server.db.exec(
    sql"DELETE FROM envelopes WHERE id BETWEEN $1 AND $2",
    dbkey(0, emptyTopic, emptyHash), dbkey(time, emptyTopic, emptyHash)
  )

proc getEnvelope*(server: MailServer, key: DBKey): Envelope =
  let str = server.db.getValue(sql"SELECT data FROM envelopes WHERE id = $1", key)
  result = str.toEnvelope()

proc archive*(server: MailServer, message: Message) =
  server.db.exec(
    SqlQuery("INSERT INTO envelopes (id, data, topic, bloom) VALUES ($1, $2, $3, B'" & toBitString(message.bloom.toSeq()) & "'::bit(512)) ON CONFLICT (id) DO NOTHING;"),
    dbkey(message.env.expiry - message.env.ttl, message.env.topic, message.hash), message.env, message.env.topic
  )
