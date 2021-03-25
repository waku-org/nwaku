import
  std/sets, 
  sqlite3_abi,
  chronos, metrics,
  libp2p/protobuf/minprotobuf,
  stew/results,
  ../sqlite,
  ../../peer_manager

export sqlite

type
  WakuPeerStorage* = ref object of RootObj
    database*: SqliteDatabase
  
  WakuPeerStorageResult*[T] = Result[T, string]

  DataProc* = proc(peerId: PeerID, storedInfo: StoredInfo,
                   connectedness: Connectedness) {.closure.}


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
  
  storedInfo.addrs = toHashSet(multiaddrSeq)  
  storedInfo.protos = toHashSet(protoSeq)

  ok(storedInfo)

proc encode*(storedInfo: StoredInfo): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, storedInfo.peerId)
  
  for multiaddr in storedInfo.addrs.items:
    pb.write(2, multiaddr)
  
  for proto in storedInfo.protos.items:
    pb.write(3, proto)
  
  pb.write(4, storedInfo.publicKey)

  return pb

##########################
# Storage implementation #
##########################

proc init*(T: type WakuPeerStorage, db: SqliteDatabase): WakuPeerStorageResult[T] =
  ## Create the "Peers" table
  ## It contains:
  ##  - peer id as primary key, stored as a blob
  ##  - stored info (serialised protobuf), stored as a blob
  ##  - last known enumerated connectedness state, stored as an integer
  let prepare = db.prepareStmt("""
    CREATE TABLE IF NOT EXISTS Peers (
        peerId BLOB PRIMARY KEY,
        storedInfo BLOB,
        connectedness INTEGER
    ) WITHOUT ROWID;
    """, NoParams, void)

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec(())
  if res.isErr:
    return err("failed to exec")

  ok(WakuPeerStorage(database: db))


proc put*(db: WakuPeerStorage,
          peerId: PeerID,
          storedInfo: StoredInfo,
          connectedness: Connectedness): WakuPeerStorageResult[void] =

  ## Adds a peer to storage
  let prepare = db.database.prepareStmt(
    "INSERT INTO Peers (peerId, storedInfo, connectedness) VALUES (?, ?, ?);",
    (seq[byte], seq[byte], int32),
    void
  )

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec((peerId.data, storedInfo.encode().buffer, int32(ord(connectedness))))
  if res.isErr:
    return err("failed")

  ok()

proc getAll*(db: WakuPeerStorage, onData: DataProc): WakuPeerStorageResult[bool] =
  ## Retrieves all peers from storage
  var gotPeers = false

  proc peer(s: ptr sqlite3_stmt) = 
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

    onData(peerId, storedInfo, connectedness)

  let res = db.database.query("SELECT peerId, storedInfo, connectedness FROM Peers", peer)
  if res.isErr:
    return err("failed")

  ok gotPeers

proc close*(db: WakuPeerStorage) = 
  ## Closes the database.
  db.database.close()