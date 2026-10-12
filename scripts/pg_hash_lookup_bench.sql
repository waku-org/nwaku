-- Builds a store schema (version 8) with many hourly partitions to measure
-- hash lookups. Not part of CI. Run against a throwaway database:
--   psql "$URL" -v partitions=3000 -v rows=200 -f scripts/pg_hash_lookup_bench.sql
-- The server needs max_locks_per_transaction high enough to lock every
-- partition and index (e.g. 1024 for 5000 partitions).
-- Message g has messageHash encode(sha256(g::text::bytea), 'hex'), so a query
-- can pick hashes spread over the whole history, e.g. g = 0, N/100, 2N/100...
-- and be measured with EXPLAIN (ANALYZE, BUFFERS).

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS messages, messages_lookup, version CASCADE;

CREATE TABLE version (version INTEGER NOT NULL);
INSERT INTO version VALUES (8);

CREATE TABLE messages (
   pubsubTopic VARCHAR NOT NULL,
   contentTopic VARCHAR NOT NULL,
   payload VARCHAR,
   version INTEGER NOT NULL,
   timestamp BIGINT NOT NULL,
   id VARCHAR NOT NULL,
   messageHash VARCHAR NOT NULL,
   meta VARCHAR default null,
   CONSTRAINT messageIndex PRIMARY KEY (messageHash, timestamp)
  ) PARTITION BY RANGE (timestamp);

CREATE INDEX idx_messages_messagehash ON messages (messagehash);
CREATE INDEX idx_messages_timestamp ON messages (timestamp);
CREATE INDEX idx_query_pubsubtopic ON messages (pubsubTopic);
CREATE INDEX idx_query_contenttopic ON messages (contentTopic);

CREATE TABLE messages_lookup (
   timestamp BIGINT NOT NULL,
   messageHash VARCHAR NOT NULL,
   CONSTRAINT messageIndexLookupTable PRIMARY KEY (messageHash, timestamp)
  ) PARTITION BY RANGE (timestamp);

-- Hourly partitions ending at the current hour, named like the driver does.
SELECT format(
  'CREATE TABLE messages_%1$s_%2$s PARTITION OF messages FOR VALUES FROM (%1$s000000000) TO (%2$s000000000);
   CREATE TABLE lookup_%1$s_%2$s PARTITION OF messages_lookup FOR VALUES FROM (%1$s000000000) TO (%2$s000000000);',
  s, s + 3600)
FROM (
  SELECT (extract(epoch FROM date_trunc('hour', now()))::bigint - i * 3600) AS s
  FROM generate_series(1, :partitions) AS i
) p
\gexec

INSERT INTO messages (pubsubTopic, contentTopic, payload, version, timestamp, id, messageHash)
SELECT '/waku/2/rs/16/32',
       '/app/1/topic-' || (g % 50) || '/proto',
       repeat(md5(g::text), 6),
       0,
       ts,
       md5(g::text),
       encode(sha256(g::text::bytea), 'hex')
FROM (
  SELECT g,
         (extract(epoch FROM date_trunc('hour', now()))::bigint - :partitions * 3600) * 1000000000
           + (g * (3600::bigint * 1000000000 * :partitions / (:partitions * :rows))) AS ts
  FROM generate_series(0, :partitions * :rows - 1) AS g
) r;

INSERT INTO messages_lookup (messageHash, timestamp) SELECT messageHash, timestamp FROM messages;

VACUUM ANALYZE messages;
VACUUM ANALYZE messages_lookup;
