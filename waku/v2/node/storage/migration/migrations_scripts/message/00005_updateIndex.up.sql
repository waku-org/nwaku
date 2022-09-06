DROP INDEX IF EXISTS i_rt;

CREATE INDEX IF NOT EXISTS i_msg ON Message (contentTopic, pubsubTopic, senderTimestamp, id);
