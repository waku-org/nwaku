ALTER TABLE message RENAME COLUMN receiverTimestamp TO storedAt;


DROP INDEX IF EXISTS i_msg;

CREATE INDEX IF NOT EXISTS i_query ON message (contentTopic, pubsubTopic, storedAt, id);


DROP INDEX IF EXISTS i_rt;

CREATE INDEX IF NOT EXISTS i_ts ON message (storedAt);
