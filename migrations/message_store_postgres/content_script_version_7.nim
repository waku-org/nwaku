const ContentScriptVersion_7* =
  """
-- Create a new table to hold the last online timestamp
CREATE TABLE last_online (timestamp BIGINT NOT NULL);

-- Insert a placeholder first value
INSERT INTO last_online (timestamp) VALUES(1);

-- Update to new version 
UPDATE version SET version = 7 WHERE version = 6;
"""
