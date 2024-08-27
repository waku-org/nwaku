CREATE TABLE IF NOT EXISTS  NotDeliveredMessages(
        messageHash BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        meta BLOB,
        version INTEGER NOT NULL
    );