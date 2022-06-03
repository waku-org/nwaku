{.push raises: [Defect].}

import
  std/sets, 
  sqlite3_abi,
  libp2p/protobuf/minprotobuf,
  stew/results,
  ./peer_storage,
  ../sqlite,
  ../../peer_manager/waku_peer_store

export sqlite

type
  WakuPeerStorage* = ref object of PeerStorage
    database*: SqliteDatabase
    replaceStmt: SqliteStmt[(seq[byte], seq[byte], int32, int64), void]

##########################
# Protobuf Serialisation #
##########################

proc init*(T: type StoredInfo, buffer: seq[byte]): ProtoResult[T] =
  var
    multiaddrSeq: seq[MultiAddress]
    protoSeq: seq[string]
    storedInfo = StoredInfo()

  var pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, storedInfo.peerId)
  discard ? pb.getRepeatedField(2, multiaddrSeq)
  discard ? pb.getRepeatedField(3, protoSeq)
  discard ? pb.getField(4, storedInfo.publicKey)
  
  storedInfo.addrs = multiaddrSeq
  storedInfo.protos = protoSeq

  ok(storedInfo)

proc encode*(storedInfo: StoredInfo): PeerStorageResult[ProtoBuffer] =
  var pb = initProtoBuffer()

  pb.write(1, storedInfo.peerId)
  
  for multiaddr in storedInfo.addrs.items:
    pb.write(2, multiaddr)
  
  for proto in storedInfo.protos.items:
    pb.write(3, proto)
  
  try:
    pb.write(4, storedInfo.publicKey)
  except ResultError[CryptoError] as e:
    return err("Failed to encode public key")

  ok(pb)

##########################
# Storage implementation #
##########################

proc new*(T: type WakuPeerStorage, db: SqliteDatabase): PeerStorageResult[T] =
  
  ## Create the "Peer" table
  ## It contains:
  ##  - peer id as primary key, stored as a blob
  ##  - stored info (serialised protobuf), stored as a blob
  ##  - last known enumerated connectedness state, stored as an integer
  ##  - disconnect time in epoch seconds, if applicable
  let
    createStmt = db.prepareStmt("""
      CREATE TABLE IF NOT EXISTS Peer (
          peerId BLOB PRIMARY KEY,
          storedInfo BLOB,
          connectedness INTEGER,
          disconnectTime INTEGER
      ) WITHOUT ROWID;
      """, NoParams, void).expect("this is a valid statement")

  let res = createStmt.exec(())
  if res.isErr:
    return err("failed to exec")

  # We dispose of this prepared statement here, as we never use it again
  createStmt.dispose()

  ## Reusable prepared statements
  let
    replaceStmt = db.prepareStmt(
      "REPLACE INTO Peer (peerId, storedInfo, connectedness, disconnectTime) VALUES (?, ?, ?, ?);",
      (seq[byte], seq[byte], int32, int64),
      void
    ).expect("this is a valid statement")

  ## General initialization
  
  ok(WakuPeerStorage(database: db,
                     replaceStmt: replaceStmt))


method put*(db: WakuPeerStorage,
            peerId: PeerID,
            storedInfo: StoredInfo,
            connectedness: Connectedness,
            disconnectTime: int64): PeerStorageResult[void] =

  ## Adds a peer to storage or replaces existing entry if it already exists
  let encoded = storedInfo.encode()

  if encoded.isErr:
    return err("failed to encode: " & encoded.error())

  let res = db.replaceStmt.exec((peerId.data, encoded.get().buffer, int32(ord(connectedness)), disconnectTime))
  if res.isErr:
    return err("failed")

  ok()

method getAll*(db: WakuPeerStorage, onData: peer_storage.DataProc): PeerStorageResult[bool] =
  ## Retrieves all peers from storage
  var gotPeers = false

  proc peer(s: ptr sqlite3_stmt) {.raises: [Defect, LPError, ResultError[ProtoError]].} = 
    gotPeers = true
    let
      # Peer ID
      pId = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 0))
      pIdL = sqlite3_column_bytes(s, 0)
      peerId = PeerID.init(@(toOpenArray(pId, 0, pIdL - 1))).tryGet()
      # Stored Info
      sTo = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      sToL = sqlite3_column_bytes(s, 1)
      storedInfo = StoredInfo.init(@(toOpenArray(sTo, 0, sToL - 1))).tryGet()
      # Connectedness
      connectedness = Connectedness(sqlite3_column_int(s, 2))
      # DisconnectTime
      disconnectTime = sqlite3_column_int64(s, 3)

    onData(peerId, storedInfo, connectedness, disconnectTime)

  var queryResult: DatabaseResult[bool]
  try:
    queryResult = db.database.query("SELECT peerId, storedInfo, connectedness, disconnectTime FROM Peer", peer)
  except LPError, ResultError[ProtoError]:
    return err("failed to extract peer from query result")
  
  if queryResult.isErr:
    return err("failed")

  ok gotPeers

proc close*(db: WakuPeerStorage) = 
  ## Closes the database.
  db.replaceStmt.dispose()
  db.database.close()