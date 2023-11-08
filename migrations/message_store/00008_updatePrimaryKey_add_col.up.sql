ALTER TABLE message RENAME TO message_backup;

CREATE TABLE IF NOT EXISTS message (
  pubsubTopic BLOB NOT NULL,
  contentTopic BLOB NOT NULL,
  payload BLOB,
  version INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  id BLOB,
  messageHash BLOB, -- Newly added, this will be populated with a counter value
  storedAt INTEGER NOT NULL,
  CONSTRAINT messageIndex PRIMARY KEY (storedAt, messageHash)
) WITHOUT ROWID;


INSERT INTO message(pubsubTopic, contentTopic, payload, version, timestamp, id, messageHash, storedAt)
SELECT
  mb.pubsubTopic,
  mb.contentTopic,
  mb.payload,
  mb.version,
  mb.timestamp,
  mb.id,
  (
    SELECT COUNT(*)
    FROM message_backup AS mb2
    WHERE mb2.storedAt <= mb.storedAt
  ) as messageHash, -- to populate the counter values
  mb.storedAt
FROM message_backup AS mb;

DROP TABLE message_backup;