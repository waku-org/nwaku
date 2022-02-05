CREATE TABLE IF NOT EXISTS Message_backup (
        id BLOB PRIMARY KEY,
        receiverTimestamp REAL NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp REAL NOT NULL
    ) WITHOUT ROWID;

INSERT INTO Message_backup SELECT id, receiverTimestamp, contentTopic, pubsubTopic, payload, version, senderTimestamp FROM Message;

DROP TABLE Message;

CREATE TABLE IF NOT EXISTS Message(
        id BLOB PRIMARY KEY,
        receiverTimestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp INTEGER NOT NULL
    ) WITHOUT ROWID;


INSERT INTO Message (id, receiverTimestamp, contentTopic, pubsubTopic, payload, version, senderTimestamp)
    SELECT id, FLOOR(receiverTimestamp*1000000000), contentTopic, pubsubTopic, payload, version, FLOOR(senderTimestamp*1000000000)
    FROM Message_backup;

DROP TABLE Message_backup;