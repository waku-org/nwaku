ALTER TABLE Message RENAME TO Message_backup;

CREATE TABLE IF NOT EXISTS Message(
        id BLOB,
        receiverTimestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp INTEGER NOT NULL,
        CONSTRAINT messageIndex PRIMARY KEY (senderTimestamp, id, pubsubTopic)
    ) WITHOUT ROWID;

INSERT INTO Message
    SELECT *
    FROM Message_backup;

DROP TABLE Message_backup;