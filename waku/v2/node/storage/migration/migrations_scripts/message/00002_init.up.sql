CREATE TABLE IF NOT EXISTS Message_backup (
        id BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL
    ) WITHOUT ROWID;

INSERT INTO Message_backup SELECT id, timestamp, contentTopic, pubsubTopic, payload, version FROM Message;

DROP TABLE Message;

CREATE TABLE IF NOT EXISTS Message(
        id BLOB PRIMARY KEY,
        receiverTimestamp REAL NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp REAL NOT NULL
    ) WITHOUT ROWID;


INSERT INTO Message SELECT id, timestamp, contentTopic, pubsubTopic, payload, version, 0  FROM Message_backup;

DROP TABLE Message_backup;