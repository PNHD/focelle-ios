ALTER TABLE events ADD COLUMN category TEXT;
ALTER TABLE events ADD COLUMN latency_bucket TEXT;
ALTER TABLE events ADD COLUMN schema_version INTEGER;

CREATE UNIQUE INDEX events_device_milestone
  ON events (device_hash, name)
  WHERE name IN ('activation', 'day_1_return', 'day_7_return');
