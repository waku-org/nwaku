const ContentScriptVersion_4* =
  """
ALTER TABLE IF EXISTS messages_backup RENAME TO messages;
ALTER TABLE messages RENAME TO messages_backup;
ALTER TABLE messages_backup DROP CONSTRAINT messageIndex;

CREATE TABLE IF NOT EXISTS messages (
   pubsubTopic VARCHAR NOT NULL,
   contentTopic VARCHAR NOT NULL,
   payload VARCHAR,
   version INTEGER NOT NULL,
   timestamp BIGINT NOT NULL,
   id VARCHAR NOT NULL,
   messageHash VARCHAR NOT NULL,
   storedAt BIGINT NOT NULL,
   meta VARCHAR,
   CONSTRAINT messageIndex PRIMARY KEY (messageHash, storedAt)
  ) PARTITION BY RANGE (storedAt);

INSERT INTO messages (
                        pubsubTopic,
                        contentTopic,
                        payload,
                        version,
                        timestamp,
                        id,
                        messageHash,
                        storedAt
                     )
                SELECT pubsubTopic,
                       contentTopic,
                       payload,
                       version,
                       timestamp,
                       id,
                       messageHash,
                       storedAt
                   FROM messages_backup;

DROP TABLE messages_backup;

UPDATE version SET version = 4 WHERE version = 3;

"""
