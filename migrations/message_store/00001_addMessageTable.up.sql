CREATE TABLE IF NOT EXISTS  Message(
        id BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL
    ) WITHOUT ROWID;