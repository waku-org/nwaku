const ContentScriptVersion_3* =
  """
CREATE INDEX IF NOT EXISTS i_query ON messages
  (contentTopic, pubsubTopic, storedAt, id);

"""
