## This MUST be run after v6
## This script MUST be run for each partitions in the DB.
## Then the old_messages table can be dropped.
const ContentScriptVersion_6.1* =
  """
DO $$
DECLARE
	partition_name TEXT;
	partition_count numeric;
BEGIN
    
	SELECT child.relname AS partition_name FROM pg_inherits
	JOIN pg_class parent            ON pg_inherits.inhparent = parent.oid
	JOIN pg_class child             ON pg_inherits.inhrelid   = child.oid
	JOIN pg_namespace nmsp_parent   ON nmsp_parent.oid  = parent.relnamespace
	JOIN pg_namespace nmsp_child    ON nmsp_child.oid   = child.relnamespace
	WHERE parent.relname='old_messages'
	ORDER BY partition_name ASC LIMIT 1 INTO partition_name;

	-- Get the number of rows of this partition
	EXECUTE format('SELECT COUNT(1) FROM %I', partition_name) INTO partition_count;

	IF partition_count > 0 THEN
   
	-- Insert partition rows into new table
	EXECUTE format('INSERT INTO new_%I (messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta)
		SELECT messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta
		FROM %I', partition_name, partition_name);

	-- Drop old partition.
	EXECUTE format('DROP TABLE %I', partition_name);

	-- Rename new partition
	EXECUTE format('ALTER TABLE new_%I RENAME TO %I', partition_name, partition_name);	

	END IF;

END $$;
"""
