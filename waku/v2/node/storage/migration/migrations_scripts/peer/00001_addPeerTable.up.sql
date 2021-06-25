CREATE TABLE IF NOT EXISTS Peer (
        peerId BLOB PRIMARY KEY,
        storedInfo BLOB,
        connectedness INTEGER,
        disconnectTime INTEGER
    ) WITHOUT ROWID;