CREATE INDEX IF NOT EXISTS i_msg ON Message (contentTopic, pubsubTopic, senderTimestamp, id);
