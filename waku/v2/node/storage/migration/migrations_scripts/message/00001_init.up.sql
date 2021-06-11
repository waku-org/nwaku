/* Copy the accounts table into a temp table, EXCLUDE the `photoPath` and INCLUDE `identicon` column */
CREATE TABLE IF NOT EXISTS Message_backup (
        id BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL
    ) WITHOUT ROWID;

INSERT INTO Message_backup SELECT id, timestamp, contentTopic, pubsubTopic, payload, version FROM Message;

/* Drop the old Message table*/
DROP TABLE Message;

/* create a new Message Table with updated schema*/
CREATE TABLE IF NOT EXISTS Message(
        id BLOB PRIMARY KEY,
        receiverTimestamp BLOB NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp BLOB NOT NULL
    ) WITHOUT ROWID;

/**
trnasfer old content to the new table and set their sender timestamp to 0
**/
INSERT INTO Message SELECT id, timestamp, contentTopic, pubsubTopic, payload, version, 0  FROM Message_backup;

/* Tidy up, drop the backup table */
DROP TABLE Message_backup;