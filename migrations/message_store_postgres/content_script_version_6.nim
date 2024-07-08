const ContentScriptVersion_6* =
  """
-- Rename old table
ALTER TABLE MESSAGES
RENAME TO OLD_MESSAGES;

-- Remove old message index
ALTER TABLE OLD_MESSAGES
DROP CONSTRAINT MESSAGEINDEX;

-- Create new empty table
CREATE TABLE MESSAGES (
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
	   
	-- Create new partition with the same name and bounds
	EXECUTE format('CREATE TABLE new_%I PARTITION OF messages FOR VALUES FROM (%L) TO (%L)', partition_name, min_timestamp, max_timestamp + 1);

	ELSE

	-- Drop old partition.
	EXECUTE format('DROP TABLE %I', partition_name);

	END If;
	
	END LOOP;

END $$;

-- Update to new version 
UPDATE VERSION
SET
	VERSION = 6
WHERE
	VERSION = 5;
"""
