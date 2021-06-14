CREATE TABLE IF NOT EXISTS Message_backup (
        id BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL
    ) WITHOUT ROWID;