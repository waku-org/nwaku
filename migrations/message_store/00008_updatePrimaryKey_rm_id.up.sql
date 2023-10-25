ALTER TABLE message RENAME TO message_backup;

CREATE TABLE IF NOT EXISTS message(
  pubsubTopic BLOB NOT NULL,
  contentTopic BLOB NOT NULL,
  payload BLOB,
  version INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  messageHash BLOB,
  storedAt INTEGER NOT NULL,
  CONSTRAINT messageIndex PRIMARY KEY (storedAt, messageHash)
) WITHOUT ROWID;

INSERT OR IGNORE INTO message(pubsubTopic, contentTopic, payload, version, timestamp, messageHash, storedAt)
  SELECT pubsubTopic, contentTopic, payload, version, timestamp, id, storedAt
  FROM message_backup;

DROP TABLE message_backup;