const ContentScriptVersion_6* =
  """
-- Rename old table
ALTER TABLE IF EXISTS MESSAGES
RENAME TO OLD_MESSAGES;

-- Remove old message index
ALTER TABLE IF EXISTS OLD_MESSAGES
DROP CONSTRAINT MESSAGEINDEX;

-- Create new empty table
CREATE TABLE IF NOT EXISTS NEW_MESSAGES (
	MESSAGEHASH VARCHAR NOT NULL,
	PUBSUBTOPIC VARCHAR NOT NULL,
	CONTENTTOPIC VARCHAR NOT NULL,
	PAYLOAD VARCHAR,
	VERSION INTEGER NOT NULL,
	TIMESTAMP BIGINT NOT NULL,
	META VARCHAR,
	CONSTRAINT MESSAGEINDEX PRIMARY KEY (TIMESTAMP, MESSAGEHASH)
)
PARTITION BY
	RANGE (TIMESTAMP);

DO $$
DECLARE
	partition_name TEXT;
	partition_count numeric;
	min_timestamp numeric;
	max_timestamp numeric;
BEGIN
    FOR partition_name in 
		(SELECT child.relname AS partition_name FROM pg_inherits
		JOIN pg_class parent            ON pg_inherits.inhparent = parent.oid
		JOIN pg_class child             ON pg_inherits.inhrelid   = child.oid
		JOIN pg_namespace nmsp_parent   ON nmsp_parent.oid  = parent.relnamespace
		JOIN pg_namespace nmsp_child    ON nmsp_child.oid   = child.relnamespace
		WHERE parent.relname='old_messages'
		ORDER BY partition_name ASC)
    LOOP

	-- Get the number of rows of this partition
	EXECUTE format('SELECT COUNT(1) FROM %I', partition_name) INTO partition_count;

	IF partition_count > 0 THEN

	-- Get the smallest timestamp of this partition
	EXECUTE format('SELECT MIN(timestamp) FROM %I', partition_name) INTO min_timestamp;

	-- Get the largest timestamp of this partition
	EXECUTE format('SELECT MAX(timestamp) FROM %I', partition_name) INTO max_timestamp;

	-- Rename old partition
	EXECUTE format('ALTER TABLE %I RENAME TO old_%I', partition_name, partition_name);

	-- Create new partition with the same name and bounds
	EXECUTE format('CREATE TABLE %I PARTITION OF new_messages FOR VALUES FROM (%L) TO (%L)', partition_name, min_timestamp, max_timestamp + 1);
	
	-- Insert partition rows into new table
	EXECUTE format('INSERT INTO %I (messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta, id, storedAt)
		SELECT messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta, id, storedAt
		FROM old_%I', partition_name, partition_name);

	-- Drop old partition.
	EXECUTE format('DROP TABLE old_%I', partition_name);
	
	END IF;
	
	END LOOP;
END $$;

-- Remove old table
DROP TABLE IF EXISTS OLD_MESSAGES;

-- Rename new table
ALTER TABLE IF EXISTS NEW_MESSAGES
RENAME TO MESSAGES;

-- Update to new version 
UPDATE VERSION
SET
	VERSION = 6
WHERE
	VERSION = 5;
"""
