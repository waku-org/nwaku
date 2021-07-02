CREATE TABLE IF NOT EXISTS Message_backup (
        id BLOB PRIMARY KEY,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp REAL NOT NULL
    ) WITHOUT ROWID;

INSERT INTO Message_backup SELECT id, contentTopic, pubsubTopic, payload, version, senderTimestamp  FROM Message;

DROP TABLE Message;

CREATE TABLE IF NOT EXISTS Message(
        id BLOB PRIMARY KEY,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp REAL NOT NULL
    ) WITHOUT ROWID;


INSERT INTO Message SELECT id, contentTopic, pubsubTopic, payload, version, senderTimestamp  FROM Message_backup;

DROP TABLE Message_backup;