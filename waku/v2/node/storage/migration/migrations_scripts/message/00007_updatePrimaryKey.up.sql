ALTER TABLE message RENAME TO message_backup;

CREATE TABLE IF NOT EXISTS message(
  pubsubTopic BLOB NOT NULL,
  contentTopic BLOB NOT NULL,
  payload BLOB,
  version INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  id BLOB,
  storedAt INTEGER NOT NULL,
  CONSTRAINT messageIndex PRIMARY KEY (storedAt, id, pubsubTopic)
) WITHOUT ROWID;

INSERT OR IGNORE INTO message(pubsubTopic, contentTopic, payload, version, timestamp, id, storedAt)
  SELECT pubsubTopic, contentTopic, payload, version, senderTimestamp, id, storedAt
  FROM message_backup;

DROP TABLE message_backup;