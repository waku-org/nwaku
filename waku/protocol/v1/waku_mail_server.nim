import
  eth/[p2p], 
  eth/p2p/rlpx_protocols/whisper/whisper_types,
  db_sqlite,
  sequtils, strformat, strutils,
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
    topics*: seq[Topic]

proc setupDB*(server: MailServer) =
  let db = open(MAILSERVER_DATABASE, "", "", "")

  # @TODO THIS PROBABLY DOES NOT BELONG HERE
  db.exec(sql"""CREATE TABLE envelopes IF NOT EXISTS (id BYTEA NOT NULL UNIQUE, data BYTEA NOT NULL, topic BYTEA NOT NULL, bloom BIT(512) NOT NULL);
    CREATE INDEX id_bloom_idx ON envelopes (id DESC, bloom);
    CREATE INDEX id_topic_idx ON envelopes (id DESC, topic);""")

  server.db = db

proc dbkey(timestamp: uint32, topic: Topic, hash: Hash): DBKey =
  result = concat(@(timestamp.toBytesBE()), @topic, @(hash.data))

proc implode(topics: seq[Topic]): string =
  for i, topic in topics:
    result &= string.fromBytes(topic) 
    if i != len(topic) - 1:
      result &= ", "

proc toBitString(bloom: seq[byte]): string =
  for n in bloom:
    result &= &"{n:08b}"

proc toEnvelope(str: string): Envelope =
  var rlp = rlpFromBytes(str.toBytes())
  result = rlp.read(Envelope)

proc findEnvelopes(server: MailServer, request: MailRequest): seq[Row] =
  var emptyTopic: Topic = [byte 0, 0, 0, 0]
  var emptyHash: Hash

  var lower = dbkey(request.lower, emptyTopic, emptyHash)

  var query: string = "SELECT id, data from envelopes WHERE id >= " & string.fromBytes(lower.toSeq) & " AND id < " 
  if len(request.cursor) > 0:
    query &= string.fromBytes(request.cursor.toSeq)
  else:
    var upper = dbkey(request.upper + 1, emptyTopic, emptyHash)
    query &= string.fromBytes(upper.toSeq)


  if len(request.topics) > 0:
    query &= " AND topic IN (" & implode(request.topics) & ")"
  else:
    query &= " AND bloom & b'" & toBitString(request.bloom.toSeq()) & "'::bit(512) = bloom"

  query &= " ORDER BY id DESC LIMIT " & $request.limit

  result = server.db.getAllRows(SqlQuery(query))

proc getEnvelopes*(server: MailServer, request: MailRequest): seq[Envelope] =
  let rows = server.findEnvelopes(request)

  for row in rows:
    result.add(row[1].toEnvelope())
  
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
