const ContentScriptVersion_6* =
  """
ALTER TABLE IF EXISTS messages_backup RENAME TO messages;
ALTER TABLE messages RENAME TO messages_backup;
ALTER TABLE messages_backup DROP CONSTRAINT messageIndex;

CREATE TABLE IF NOT EXISTS messages (
   messageHash VARCHAR NOT NULL,
   pubsubTopic VARCHAR NOT NULL,
   contentTopic VARCHAR NOT NULL,
   payload VARCHAR,
   version INTEGER NOT NULL,
   timestamp BIGINT NOT NULL,
   meta VARCHAR,
   id VARCHAR,
   storedAt BIGINT,
	CONSTRAINT messageIndex PRIMARY KEY (timestamp, messageHash)
  ) PARTITION BY RANGE (timestamp);

DO $$
DECLARE
     min_timestamp numeric;
     max_timestamp numeric;
     min_timestampSeconds integer = 0;
     max_timestampSeconds integer = 0;
     partition_name TEXT;
     create_partition_stmt TEXT;
BEGIN
    SELECT MIN(timestamp) into min_timestamp
    FROM messages_backup;

    SELECT MAX(timestamp) into max_timestamp
    FROM messages_backup;

    min_timestampSeconds := min_timestamp / 1000000000;
    max_timestampSeconds := max_timestamp / 1000000000;

    partition_name := 'messages_' || min_timestampSeconds || '_' || max_timestampSeconds;
    create_partition_stmt := 'CREATE TABLE ' || partition_name ||
                            ' PARTITION OF messages FOR VALUES FROM (' ||
                            min_timestamp || ') TO (' || (max_timestamp + 1) || ')';
    IF min_timestampSeconds > 0 AND max_timestampSeconds > 0 THEN
    	EXECUTE create_partition_stmt USING partition_name, min_timestamp, max_timestamp;
    END IF;
END $$;

INSERT INTO messages (
                        messageHash,
                        pubsubTopic,
                        contentTopic,
                        payload,
                        version,
                        timestamp,
                        meta,
                        id,
                        storedAt
                     )
                SELECT messageHash,
                        pubsubTopic,
                        contentTopic,
                        payload,
                        version,
                        timestamp,
                        meta,
                        id,
                        storedAt
                   FROM messages_backup;

DROP TABLE messages_backup;

UPDATE version SET version = 6 WHERE version = 5;
"""
