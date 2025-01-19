ALTER TABLE message DROP COLUMN timestamp;

ALTER TABLE message RENAME COLUMN storedAt TO timestamp;