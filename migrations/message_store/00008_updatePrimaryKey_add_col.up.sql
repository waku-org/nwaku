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
  CONSTRAINT messageIndex PRIMARY KEY (messageHash)
) WITHOUT ROWID;


INSERT INTO message(pubsubTopic, contentTopic, payload, version, timestamp, id, messageHash, storedAt)
SELECT
  mb.pubsubTopic,
  mb.contentTopic,
  mb.payload,
  mb.version,
  mb.timestamp,
  mb.id,
  randomblob(32), -- to populate 32-byte random blob
  mb.storedAt
FROM message_backup AS mb;

DROP TABLE message_backup;