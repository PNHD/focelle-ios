INSERT INTO app_config (key, value) VALUES ('reward_test_enabled', 'off');

CREATE TABLE credit_operations (
  idempotency_key TEXT PRIMARY KEY,
  device_hash TEXT NOT NULL,
  local_day TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('ai', 'filter')),
  status TEXT NOT NULL CHECK (status IN ('reserved', 'consumed', 'refunded')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX credit_operations_day
  ON credit_operations (device_hash, local_day, kind, status);

CREATE TABLE reward_operations (
  reward_id TEXT PRIMARY KEY,
  device_hash TEXT NOT NULL,
  local_day TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX reward_operations_day
  ON reward_operations (device_hash, local_day);
